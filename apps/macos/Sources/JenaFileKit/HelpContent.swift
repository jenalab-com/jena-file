import Foundation

/// 도움말 window text. Kept whole per language (not through `L`): it is prose, and
/// the two versions are edited side by side.
public enum HelpContent {
    public struct Section {
        public let title: String
        /// Lines starting with "• " are list items, the rest are paragraphs.
        public let lines: [String]
    }

    public static var sections: [Section] { Localization.useEnglish ? english : korean }

    public static let korean: [Section] = [
        Section(title: "jena-file은", lines: [
            "원격 파일 전송과 터미널을 한 화면에서 쓰는 SFTP 앱이에요. 경유 서버(bastion) 뒤에 있는 서버도 한 번의 접속으로 파일 창과 터미널을 함께 열어요.",
        ]),
        Section(title: "접속하기", lines: [
            "• 빠른 접속: 맨 위 막대에 호스트·사용자·비밀번호·포트를 넣고 [접속]. 호스트 칸에 user@host:port처럼 한 번에 적어도 돼요.",
            "• 저장된 서버: 파일 ▸ 서버 관리(⌘K)에서 서버를 고르고 [접속]하거나 더블클릭해요.",
            "• 처음 접속하는 서버는 호스트 키 지문을 보여 줘요. 서버 관리자에게 받은 지문과 같을 때만 신뢰하세요.",
        ]),
        Section(title: "경유 서버(bastion) 거쳐 접속하기", lines: [
            "• 빠른 접속: [경유]를 켜고 경유 서버를 user@host:port로 적어요.",
            "• 서버 관리: 「경유 서버」에서 저장된 서버를 고르거나 「직접 입력…」을 골라요. 필요한 서버에만 켜면 되고, 기본은 직접 접속이에요.",
            "• 평소 쓰던 명령이 있다면 서버 관리 ▸ [ssh 명령으로…]에 붙여 넣으세요. ssh -L / -J 명령에서 경유 서버와 내부 서버를 한 번에 만들어요.",
            "• 터미널의 [내부 서버 열기…]는 지금 셸의 서버를 경유 서버로 삼아 내부 서버를 열어요. 경유 서버에 다시 로그인하지 않아요.",
        ]),
        Section(title: "파일 창", lines: [
            "왼쪽은 이 Mac, 오른쪽은 서버예요. 각 창의 위쪽은 폴더 트리, 아래쪽은 고른 폴더의 파일 목록이에요.",
            "• 트리에서 폴더를 누르거나 목록에서 폴더를 더블클릭해 들어가요. 경로 칸에 직접 입력해도 돼요.",
            "• ↑ 상위 폴더, ⌂ 홈 폴더, 디스크 버튼으로 외장 디스크·네트워크 드라이브를 열어요(로컬).",
            "• 트리와 목록 사이 경계를 끌어 높이를 바꿀 수 있어요.",
            "• 로컬 숨김 파일은 보기 ▸ 로컬 숨김 파일 보기(⇧⌘.)로 켜고 꺼요.",
        ]),
        Section(title: "오른쪽 클릭 메뉴", lines: [
            "• 이름 복사 / 상대 경로 복사 / 절대 경로 복사: 여러 개를 고르면 한 줄에 하나씩 복사해요. 상대 경로는 홈 폴더(서버는 로그인한 폴더) 기준이고, 홈 밖이면 절대 경로로 복사해요. 빈 곳을 누르면 지금 폴더 경로를 복사해요.",
            "• 이름 바꾸기…: 파일·폴더 하나의 이름을 바꿔요. 같은 이름이 이미 있으면 바꾸지 않아요.",
            "• 업로드 / 다운로드: 고른 항목을 반대쪽 창의 지금 폴더로 보내요.",
            "• 여기서 터미널 열기 / 경로를 터미널에 넣기(원격).",
        ]),
        Section(title: "전송", lines: [
            "• 파일·폴더를 반대쪽 창으로 끌어다 놓으면 대기열에 들어가요. Finder에서 원격 창으로 끌어도 돼요.",
            "• 같은 이름이 있으면 묻기·덮어쓰기·이름 바꿔 저장·건너뛰기 중에서 골라요. 기본 동작은 설정(⌘,)에서 정해요.",
            "• 전송 칸의 오른쪽 클릭으로 일시정지·취소·이어서 받기를 해요.",
            "• 연결이 끊기면 자동으로 다시 접속하고, 끊긴 전송은 이어서 받아요. 앱을 다시 켜면 남은 대기열을 이어서 할지 물어요.",
        ]),
        Section(title: "터미널", lines: [
            "• 접속하면 같은 접속 위에 셸이 열려요. [새 셸](⌘T)로 탭을 더 열어요.",
            "• 원격 파일을 터미널로 끌어다 놓으면 경로가 입력돼요.",
        ]),
        Section(title: "서버 관리", lines: [
            "• 왼쪽은 그룹 트리예요. [새 그룹]으로 그룹을 만들고, 그룹을 고른 채 [새 서버]를 누르면 그 그룹에 들어가요.",
            "• 서버를 끌어서 다른 그룹이나 그룹 밖으로 옮겨요.",
            "• 그룹을 지울 때는 서버도 함께 지울지, 그룹 밖으로 남길지 물어요.",
            "• 비밀번호는 macOS 키체인에만 저장돼요.",
        ]),
        Section(title: "단축키", lines: [
            "• ⌘K 서버 관리 · ⌘T 새 셸 · ⌘D 연결 끊기 · ⌘, 설정",
            "• ⌥⌘1 상태 로그 · ⌥⌘2 전송 로그 · ⌥⌘3 터미널 보기 켜고 끄기",
            "• ⇧⌘. 로컬 숨김 파일 · ⌘? 이 도움말",
        ]),
    ]

    public static let english: [Section] = [
        Section(title: "About jena-file", lines: [
            "An SFTP app with remote file transfer and a terminal in one window. Servers behind a jump host (bastion) open with their file pane and terminal in one step.",
        ]),
        Section(title: "Connecting", lines: [
            "• Quick connect: fill in host, user, password and port in the top bar, then Connect. You can also type user@host:port in the host field.",
            "• Saved servers: File ▸ Servers (⌘K), pick a server and Connect, or double-click it.",
            "• A new server shows its host key fingerprint. Trust it only if it matches the one from the server's administrator.",
        ]),
        Section(title: "Connecting through a jump host", lines: [
            "• Quick connect: turn on Via and enter the jump host as user@host:port.",
            "• Servers window: choose a saved server under Jump host, or Enter manually…. Turn it on only for servers that need it; direct is the default.",
            "• Paste your usual command into Servers ▸ From ssh command…. An ssh -L / -J command creates the jump host and the internal server together.",
            "• Open Internal Server… in the terminal uses the shell's server as the jump host, without logging in again.",
        ]),
        Section(title: "File panes", lines: [
            "Left is this Mac, right is the server. Each pane has the folder tree on top and the chosen folder's files below.",
            "• Click a folder in the tree or double-click one in the list. You can also type a path.",
            "• ↑ goes up, ⌂ goes home, and the disk button opens external and network drives (local).",
            "• Drag the line between the tree and the list to resize them.",
            "• Show hidden local files with View ▸ Show Local Hidden Files (⇧⌘.).",
        ]),
        Section(title: "Right-click menu", lines: [
            "• Copy Name / Copy Relative Path / Copy Full Path: several items copy one per line. Relative paths start from the home folder (the login folder on servers); items outside it copy as full paths. Clicking empty space copies the current folder.",
            "• Rename…: renames one file or folder. An existing name is never replaced.",
            "• Upload / Download: sends the items to the other pane's current folder.",
            "• Open Terminal Here / Insert Path in Terminal (remote).",
        ]),
        Section(title: "Transfers", lines: [
            "• Drag files or folders to the other pane to queue them. Dragging from Finder to the remote pane works too.",
            "• When a name exists you choose Ask, Overwrite, Rename or Skip. Set the default in Settings (⌘,).",
            "• Right-click a transfer to pause, cancel or resume it.",
            "• Lost connections reconnect by themselves and broken transfers resume. On the next launch the app offers to finish the remaining queue.",
        ]),
        Section(title: "Terminal", lines: [
            "• Connecting opens a shell on the same connection. New Shell (⌘T) opens more tabs.",
            "• Drop remote files onto the terminal to type their paths.",
        ]),
        Section(title: "Servers", lines: [
            "• The left side is a group tree. New Group makes a group; with a group selected, New Server puts the server in it.",
            "• Drag servers into another group or out of groups.",
            "• Deleting a group asks whether its servers go too or move out of the group.",
            "• Passwords are stored only in the macOS Keychain.",
        ]),
        Section(title: "Shortcuts", lines: [
            "• ⌘K Servers · ⌘T New Shell · ⌘D Disconnect · ⌘, Settings",
            "• ⌥⌘1 Status log · ⌥⌘2 Transfers · ⌥⌘3 Terminal on/off",
            "• ⇧⌘. Hidden local files · ⌘? This help",
        ]),
    ]
}
