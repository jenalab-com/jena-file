//! Ask-the-user requests that do not block a thread (ARCHITECTURE §5):
//! the asking task awaits a oneshot, the UI answers by prompt id.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use tokio::sync::oneshot;

use crate::events::{ConnectionId, Event, EventSink, Hop, PromptAnswer, PromptId, PromptKind};

pub(crate) struct PromptBroker {
    next: AtomicU64,
    pending: Mutex<HashMap<PromptId, oneshot::Sender<PromptAnswer>>>,
    sink: Arc<dyn EventSink>,
}

impl PromptBroker {
    pub(crate) fn new(sink: Arc<dyn EventSink>) -> Self {
        Self { next: AtomicU64::new(1), pending: Mutex::new(HashMap::new()), sink }
    }

    pub(crate) async fn ask(&self, connection: ConnectionId, hop: Hop, kind: PromptKind) -> PromptAnswer {
        let prompt = self.next.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(prompt, tx);
        // If the asking task is dropped (connection cancelled) forget the prompt.
        let _guard = Forget { broker: self, prompt };
        self.sink.emit(Event::PromptRequested { prompt, connection, hop, kind });
        rx.await.unwrap_or(PromptAnswer::Cancel)
    }

    /// Returns false if the prompt is unknown or already answered.
    pub(crate) fn respond(&self, prompt: PromptId, answer: PromptAnswer) -> bool {
        match self.pending.lock().unwrap().remove(&prompt) {
            Some(tx) => tx.send(answer).is_ok(),
            None => false,
        }
    }
}

struct Forget<'a> {
    broker: &'a PromptBroker,
    prompt: PromptId,
}

impl Drop for Forget<'_> {
    fn drop(&mut self) {
        self.broker.pending.lock().unwrap().remove(&self.prompt);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Capture(Mutex<Vec<Event>>);
    impl EventSink for Capture {
        fn emit(&self, e: Event) {
            self.0.lock().unwrap().push(e);
        }
    }

    fn kind() -> PromptKind {
        PromptKind::Password { user: "u".into(), host: "h".into(), attempt: 1 }
    }

    #[tokio::test]
    async fn answer_reaches_the_asking_task() {
        let sink = Arc::new(Capture(Mutex::new(vec![])));
        let broker = Arc::new(PromptBroker::new(sink.clone()));
        let b = broker.clone();
        let task = tokio::spawn(async move { b.ask(7, Hop::Target, kind()).await });
        tokio::task::yield_now().await;
        let id = loop {
            if let Some(Event::PromptRequested { prompt, connection: 7, .. }) = sink.0.lock().unwrap().first().cloned() {
                break prompt;
            }
            tokio::task::yield_now().await;
        };
        assert!(broker.respond(id, PromptAnswer::Secret("pw".into())));
        assert_eq!(task.await.unwrap(), PromptAnswer::Secret("pw".into()));
        assert!(!broker.respond(id, PromptAnswer::Cancel), "second answer is ignored");
    }

    #[tokio::test]
    async fn dropped_asker_forgets_prompt() {
        let sink = Arc::new(Capture(Mutex::new(vec![])));
        let broker = Arc::new(PromptBroker::new(sink.clone()));
        let b = broker.clone();
        let task = tokio::spawn(async move { b.ask(1, Hop::Target, kind()).await });
        tokio::task::yield_now().await;
        task.abort();
        let _ = task.await;
        assert!(broker.pending.lock().unwrap().is_empty());
    }
}
