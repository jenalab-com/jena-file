//! Turns a pasted `ssh ...` command into a target (+ bastion) so people can bring
//! their habit as-is (기획서 FR-09), e.g. `ssh -L 2222:<internal>:22 user@<bastion>`.

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostSpec {
    pub user: Option<String>,
    pub host: String,
    pub port: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ParsedSsh {
    /// Where the user ends up. For `-L` this is the forwarded internal host.
    pub target: Option<HostSpec>,
    pub bastion: Option<HostSpec>,
    /// `-L` local port. Not needed any more (no local port is opened); reported so the UI can say so.
    pub dropped_local_port: Option<u16>,
    /// Options that were recognised but not used (e.g. `-i key`, `-o X=Y`).
    pub ignored: Vec<String>,
}

/// Options that take an argument (from ssh(1)).
const WITH_ARG: &str = "BbcDEeFIiJLlmOoPpQRSWw";

pub fn parse_ssh_command(text: &str) -> Option<ParsedSsh> {
    let words = split_words(text)?;
    let mut it = words.iter().map(String::as_str).peekable();
    if it.next()? != "ssh" {
        return None;
    }
    let mut out = ParsedSsh::default();
    let (mut port, mut login, mut dest, mut forward) = (None, None, None::<String>, None::<(String, u16)>);
    let mut jump = None::<String>;

    while let Some(w) = it.next() {
        if let Some(opts) = w.strip_prefix('-').filter(|o| !o.is_empty()) {
            // Grouped flags (`-tt`, `-vN`); the first option taking an argument ends the group.
            for (i, c) in opts.char_indices() {
                if !WITH_ARG.contains(c) {
                    continue;
                }
                let rest = &opts[i + c.len_utf8()..];
                let arg = if rest.is_empty() { it.next()?.to_string() } else { rest.to_string() };
                match c {
                    'p' => port = Some(arg.parse().ok()?),
                    'l' => login = Some(arg),
                    'J' => jump = Some(arg),
                    'L' => {
                        if forward.is_none() {
                            let (lport, host, hport) = parse_forward(&arg)?;
                            out.dropped_local_port = Some(lport);
                            forward = Some((host, hport));
                        }
                    }
                    'o' => match arg.split_once('=') {
                        Some((k, v)) if k.eq_ignore_ascii_case("ProxyJump") => jump = Some(v.to_string()),
                        Some((k, v)) if k.eq_ignore_ascii_case("Port") => port = Some(v.parse().ok()?),
                        Some((k, v)) if k.eq_ignore_ascii_case("User") => login = Some(v.to_string()),
                        _ => out.ignored.push(format!("-o {arg}")),
                    },
                    other => out.ignored.push(format!("-{other} {arg}")),
                }
                break;
            }
        } else if dest.is_none() {
            dest = Some(w.to_string());
        } else {
            out.ignored.push(w.to_string()); // remote command
        }
    }

    let mut destination = parse_host(&dest?, 22)?;
    if let Some(p) = port {
        destination.port = p;
    }
    if destination.user.is_none() {
        destination.user = login;
    }
    match (forward, jump) {
        (Some((host, hport)), _) => {
            // `ssh -L l:host:hp bastion`: the destination is the bastion.
            out.bastion = Some(destination);
            out.target = Some(HostSpec { user: None, host, port: hport });
        }
        (None, Some(j)) => {
            // `-J a,b` chains; MVP 1차 supports one hop, use the first.
            out.bastion = Some(parse_host(j.split(',').next()?, 22)?);
            out.target = Some(destination);
        }
        (None, None) => out.target = Some(destination),
    }
    Some(out)
}

/// `[user@]host[:port]`, `[user@][v6]:port`.
fn parse_host(s: &str, default_port: u16) -> Option<HostSpec> {
    let s = s.strip_prefix("ssh://").unwrap_or(s);
    let (user, rest) = match s.rsplit_once('@') {
        Some((u, r)) => (Some(u.to_string()), r),
        None => (None, s),
    };
    let (host, port) = if let Some(v6) = rest.strip_prefix('[') {
        let (h, after) = v6.split_once(']')?;
        (h.to_string(), after.strip_prefix(':').map(str::parse).transpose().ok()?.unwrap_or(default_port))
    } else {
        match rest.rsplit_once(':') {
            Some((h, p)) => (h.to_string(), p.parse().ok()?),
            None => (rest.to_string(), default_port),
        }
    };
    (!host.is_empty()).then_some(HostSpec { user, host, port })
}

/// `[bind:]lport:host:hport`
fn parse_forward(s: &str) -> Option<(u16, String, u16)> {
    let parts: Vec<&str> = s.split(':').collect();
    let p = match parts.len() {
        3 => parts,
        4 => parts[1..].to_vec(),
        _ => return None,
    };
    Some((p[0].parse().ok()?, p[1].trim_matches(['[', ']']).to_string(), p[2].parse().ok()?))
}

/// Shell-like word split with '...' and "..." quoting.
fn split_words(s: &str) -> Option<Vec<String>> {
    let (mut words, mut cur, mut quote, mut has) = (Vec::new(), String::new(), None, false);
    for c in s.trim().chars() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some(_), c) => cur.push(c),
            (None, '\'' | '"') => { quote = Some(c); has = true; }
            (None, c) if c.is_whitespace() => {
                if has || !cur.is_empty() { words.push(std::mem::take(&mut cur)); has = false; }
            }
            (None, c) => cur.push(c),
        }
    }
    if quote.is_some() { return None; }
    if has || !cur.is_empty() { words.push(cur); }
    Some(words)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h(user: Option<&str>, host: &str, port: u16) -> HostSpec {
        HostSpec { user: user.map(Into::into), host: host.into(), port }
    }

    #[test]
    fn local_forward_becomes_bastion_and_internal_target() {
        // The author's habit (addresses are documentation examples, RFC 5737).
        let p = parse_ssh_command("ssh -L 2222:10.0.2.6:22 ops@203.0.113.10").unwrap();
        assert_eq!(p.bastion, Some(h(Some("ops"), "203.0.113.10", 22)));
        assert_eq!(p.target, Some(h(None, "10.0.2.6", 22)));
        assert_eq!(p.dropped_local_port, Some(2222));
    }

    #[test]
    fn jump_host_forms() {
        let p = parse_ssh_command("ssh -J jump@b.example:2200 app@10.0.0.5").unwrap();
        assert_eq!(p.bastion, Some(h(Some("jump"), "b.example", 2200)));
        assert_eq!(p.target, Some(h(Some("app"), "10.0.0.5", 22)));

        let p = parse_ssh_command("ssh -o ProxyJump=b.example -p 2201 -l app 10.0.0.5").unwrap();
        assert_eq!(p.bastion, Some(h(None, "b.example", 22)));
        assert_eq!(p.target, Some(h(Some("app"), "10.0.0.5", 2201)));
    }

    #[test]
    fn plain_and_grouped_flags() {
        let p = parse_ssh_command("ssh -tt -p2201 jena@127.0.0.1").unwrap();
        assert_eq!(p.target, Some(h(Some("jena"), "127.0.0.1", 2201)));
        assert_eq!(p.bastion, None);

        let p = parse_ssh_command("ssh -i '~/.ssh/my key' -v host.example uptime").unwrap();
        assert_eq!(p.target, Some(h(None, "host.example", 22)));
        assert_eq!(p.ignored, ["-i ~/.ssh/my key", "uptime"]);
    }

    #[test]
    fn rejects_non_ssh_and_broken_input() {
        assert_eq!(parse_ssh_command("scp a b"), None);
        assert_eq!(parse_ssh_command("ssh -p"), None);
        assert_eq!(parse_ssh_command("ssh -L 2222:bad user@h"), None);
        assert_eq!(parse_ssh_command("ssh 'unterminated"), None);
    }
}
