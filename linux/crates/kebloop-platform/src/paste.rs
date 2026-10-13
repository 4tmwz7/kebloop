//! Optional paste simulation (`wtype` / `ydotool`) used by snippet "Insert".

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use crate::compositor::{Compositor, CompositorError, Window, WindowId};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PasteTool {
    Wtype,
    Ydotool,
}

impl PasteTool {
    pub fn program(self) -> &'static str {
        match self {
            Self::Wtype => "wtype",
            Self::Ydotool => "ydotool",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PasteChord {
    CtrlV,
    /// Terminals.
    CtrlShiftV,
}

#[derive(Debug, thiserror::Error)]
pub enum PasteError {
    #[error("neither wtype nor ydotool is installed")]
    NoTool,
    #[error("{0} failed: {1}")]
    Failed(&'static str, String),
    #[error("Copied. Paste cancelled because the active window changed.")]
    FocusChanged,
    #[error("Copied. The previous window did not regain focus, so nothing was pasted.")]
    FocusTimeout,
    #[error("Copied. Could not verify which window has focus: {0}")]
    FocusUnverifiable(String),
    #[error("Paste cancelled because the clipboard changed.")]
    ClipboardChanged,
    #[error("Paste cancelled.")]
    Cancelled,
}

fn is_executable(path: &std::path::Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Finds the first available tool (`wtype` preferred) in `path_dirs`.
pub fn detect_paste_tool(path_dirs: &[PathBuf]) -> Option<PasteTool> {
    [PasteTool::Wtype, PasteTool::Ydotool]
        .into_iter()
        .find(|t| {
            path_dirs
                .iter()
                .any(|d| is_executable(&d.join(t.program())))
        })
}

/// Same, using the process `PATH`.
pub fn detect_paste_tool_in_path() -> Option<PasteTool> {
    detect_paste_tool(&crate::paths::Env::from_process().path_dirs())
}

/// Program and arguments that perform `chord`.
pub fn paste_command(tool: PasteTool, chord: PasteChord) -> (&'static str, Vec<&'static str>) {
    match (tool, chord) {
        (PasteTool::Wtype, PasteChord::CtrlV) => ("wtype", vec!["-M", "ctrl", "v", "-m", "ctrl"]),
        (PasteTool::Wtype, PasteChord::CtrlShiftV) => (
            "wtype",
            vec![
                "-M", "ctrl", "-M", "shift", "v", "-m", "shift", "-m", "ctrl",
            ],
        ),
        // Linux input event codes: ctrl 29, shift 42, v 47.
        (PasteTool::Ydotool, PasteChord::CtrlV) => {
            ("ydotool", vec!["key", "29:1", "47:1", "47:0", "29:0"])
        }
        (PasteTool::Ydotool, PasteChord::CtrlShiftV) => (
            "ydotool",
            vec!["key", "29:1", "42:1", "47:1", "47:0", "42:0", "29:0"],
        ),
    }
}

/// Sends the paste chord to the focused window. Blocking; call off the UI thread
/// after the launcher panel released keyboard focus.
pub fn simulate_paste(tool: PasteTool, chord: PasteChord) -> Result<(), PasteError> {
    let (program, args) = paste_command(tool, chord);
    let output = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .output()
        .map_err(|e| PasteError::Failed(program, e.to_string()))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(PasteError::Failed(
            program,
            String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        ))
    }
}

/// The window that should receive the paste.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PasteTarget {
    pub window: WindowId,
}

/// Timing and expectations for [`paste_into`] (mirrors `PasteService.swift`).
#[derive(Debug, Clone)]
pub struct PasteRequest {
    pub tool: PasteTool,
    pub chord: PasteChord,
    /// The window focused before the launcher opened. `None` pastes blindly
    /// after `blind_delay` (no compositor IPC), reported as unverified.
    pub target: Option<PasteTarget>,
    /// Kebloop's own process id: its windows count as "focus not returned yet".
    pub own_pid: u32,
    /// Clipboard revision at the time of the request; the paste is cancelled if it changes.
    pub clipboard_revision: Option<u64>,
    /// Lets the launcher hide and the Return key-up settle.
    pub initial_delay: Duration,
    pub poll_interval: Duration,
    pub attempts: u32,
    /// Delay used when focus cannot be verified.
    pub blind_delay: Duration,
}

impl PasteRequest {
    /// Same timing as macOS: 120 ms settle, then 15 polls 30 ms apart.
    pub fn new(tool: PasteTool, chord: PasteChord, target: Option<PasteTarget>) -> Self {
        Self {
            tool,
            chord,
            target,
            own_pid: std::process::id(),
            clipboard_revision: None,
            initial_delay: Duration::from_millis(120),
            poll_interval: Duration::from_millis(30),
            attempts: 15,
            blind_delay: Duration::from_millis(250),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PasteOutcome {
    /// The chord was sent. `focus_verified` is false when there was no way to
    /// check that the intended window had focus (the key press was still delivered
    /// successfully to the input tool, nothing more is known).
    Sent { focus_verified: bool },
}

/// Everything [`paste_into`] needs from the outside (mockable).
pub trait PasteEnvironment {
    fn focused_window(&self) -> Result<Option<Window>, CompositorError>;
    fn clipboard_revision(&self) -> Option<u64>;
    fn send(&self, tool: PasteTool, chord: PasteChord) -> Result<(), PasteError>;
    fn sleep(&self, duration: Duration);
    fn is_cancelled(&self) -> bool;
}

/// Waits for focus to return to `request.target`, then sends the chord.
/// Blocking: call off the UI thread after the launcher released keyboard focus.
/// Fails (never claims success) when the focused window is some other window,
/// focus does not return in time, the clipboard changes, or the tool fails.
pub fn paste_into(
    environment: &dyn PasteEnvironment,
    request: &PasteRequest,
) -> Result<PasteOutcome, PasteError> {
    environment.sleep(request.initial_delay);
    let Some(target) = &request.target else {
        environment.sleep(request.blind_delay);
        check_unchanged(environment, request)?;
        environment.send(request.tool, request.chord)?;
        return Ok(PasteOutcome::Sent {
            focus_verified: false,
        });
    };
    for attempt in 0..request.attempts.max(1) {
        if attempt > 0 {
            environment.sleep(request.poll_interval);
        }
        check_unchanged(environment, request)?;
        match environment.focused_window() {
            Ok(Some(window)) if window.id == target.window => {
                environment.send(request.tool, request.chord)?;
                return Ok(PasteOutcome::Sent {
                    focus_verified: true,
                });
            }
            // Our own window still holds focus: keep waiting.
            Ok(Some(window)) if window.pid == Some(request.own_pid) => {}
            Ok(Some(_)) => return Err(PasteError::FocusChanged),
            // Layer surface or nothing focused yet.
            Ok(None) => {}
            Err(error) => return Err(PasteError::FocusUnverifiable(error.to_string())),
        }
    }
    Err(PasteError::FocusTimeout)
}

fn check_unchanged(
    environment: &dyn PasteEnvironment,
    request: &PasteRequest,
) -> Result<(), PasteError> {
    if environment.is_cancelled() {
        return Err(PasteError::Cancelled);
    }
    match (request.clipboard_revision, environment.clipboard_revision()) {
        (Some(expected), Some(now)) if expected != now => Err(PasteError::ClipboardChanged),
        _ => Ok(()),
    }
}

/// Real environment: compositor IPC for focus, `wtype`/`ydotool` for the keys.
pub struct LivePasteEnvironment<'a> {
    pub compositor: Option<&'a dyn Compositor>,
    pub cancel: Option<&'a AtomicBool>,
    pub clipboard_revision: Option<&'a (dyn Fn() -> u64 + Sync)>,
}

impl PasteEnvironment for LivePasteEnvironment<'_> {
    fn focused_window(&self) -> Result<Option<Window>, CompositorError> {
        match self.compositor {
            Some(compositor) => compositor.focused_window(),
            None => Err(CompositorError::Unavailable("no compositor IPC".into())),
        }
    }

    fn clipboard_revision(&self) -> Option<u64> {
        self.clipboard_revision.map(|f| f())
    }

    fn send(&self, tool: PasteTool, chord: PasteChord) -> Result<(), PasteError> {
        simulate_paste(tool, chord)
    }

    fn sleep(&self, duration: Duration) {
        std::thread::sleep(duration);
    }

    fn is_cancelled(&self) -> bool {
        self.cancel.is_some_and(|c| c.load(Ordering::Relaxed))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use tempfile::TempDir;

    fn install(dir: &std::path::Path, name: &str) {
        let p = dir.join(name);
        std::fs::write(&p, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[test]
    fn detection_prefers_wtype() {
        let tmp = TempDir::new().unwrap();
        let dirs = vec![tmp.path().to_path_buf()];
        assert_eq!(detect_paste_tool(&dirs), None);
        install(tmp.path(), "ydotool");
        assert_eq!(detect_paste_tool(&dirs), Some(PasteTool::Ydotool));
        install(tmp.path(), "wtype");
        assert_eq!(detect_paste_tool(&dirs), Some(PasteTool::Wtype));
    }

    #[test]
    fn commands() {
        assert_eq!(
            paste_command(PasteTool::Wtype, PasteChord::CtrlV),
            ("wtype", vec!["-M", "ctrl", "v", "-m", "ctrl"])
        );
        let (p, a) = paste_command(PasteTool::Ydotool, PasteChord::CtrlShiftV);
        assert_eq!(p, "ydotool");
        assert_eq!(a.last(), Some(&"29:0"));
        assert!(a.contains(&"42:1"));
    }

    use std::cell::{Cell, RefCell};

    struct Env {
        focus: RefCell<Vec<Result<Option<Window>, CompositorError>>>,
        revision: Cell<Option<u64>>,
        cancelled: Cell<bool>,
        sent: RefCell<Vec<(PasteTool, PasteChord)>>,
        send_fails: bool,
        slept: Cell<Duration>,
        polls: Cell<u32>,
    }

    impl Env {
        fn new(focus: Vec<Result<Option<Window>, CompositorError>>) -> Self {
            Self {
                focus: RefCell::new(focus),
                revision: Cell::new(None),
                cancelled: Cell::new(false),
                sent: RefCell::default(),
                send_fails: false,
                slept: Cell::new(Duration::ZERO),
                polls: Cell::new(0),
            }
        }
    }

    impl PasteEnvironment for Env {
        fn focused_window(&self) -> Result<Option<Window>, CompositorError> {
            self.polls.set(self.polls.get() + 1);
            let mut queue = self.focus.borrow_mut();
            if queue.len() > 1 {
                queue.remove(0)
            } else {
                // The last answer repeats.
                match queue.first() {
                    Some(Ok(w)) => Ok(w.clone()),
                    Some(Err(e)) => Err(CompositorError::Io(e.to_string())),
                    None => Ok(None),
                }
            }
        }
        fn clipboard_revision(&self) -> Option<u64> {
            self.revision.get()
        }
        fn send(&self, tool: PasteTool, chord: PasteChord) -> Result<(), PasteError> {
            if self.send_fails {
                return Err(PasteError::Failed("wtype", "no virtual keyboard".into()));
            }
            self.sent.borrow_mut().push((tool, chord));
            Ok(())
        }
        fn sleep(&self, duration: Duration) {
            self.slept.set(self.slept.get() + duration);
        }
        fn is_cancelled(&self) -> bool {
            self.cancelled.get()
        }
    }

    fn window(id: &str, pid: u32) -> Window {
        Window {
            id: WindowId(id.into()),
            app_id: None,
            title: String::new(),
            pid: Some(pid),
            focused: true,
            floating: false,
            fullscreen: false,
            hidden: false,
            output: None,
            workspace: None,
            frame: None,
            size: None,
            focus_rank: None,
        }
    }

    fn request(target: Option<&str>) -> PasteRequest {
        PasteRequest {
            own_pid: 4242,
            ..PasteRequest::new(
                PasteTool::Wtype,
                PasteChord::CtrlV,
                target.map(|t| PasteTarget {
                    window: WindowId(t.into()),
                }),
            )
        }
    }

    #[test]
    fn waits_for_focus_to_return_then_pastes() {
        let env = Env::new(vec![
            Ok(None),
            Ok(Some(window("own", 4242))),
            Ok(Some(window("7", 10))),
        ]);
        let outcome = paste_into(&env, &request(Some("7"))).unwrap();
        assert_eq!(
            outcome,
            PasteOutcome::Sent {
                focus_verified: true
            }
        );
        assert_eq!(env.polls.get(), 3);
        assert_eq!(
            *env.sent.borrow(),
            vec![(PasteTool::Wtype, PasteChord::CtrlV)]
        );
        // 120 ms settle + two 30 ms polls.
        assert_eq!(env.slept.get(), Duration::from_millis(180));
    }

    #[test]
    fn another_window_cancels_the_paste() {
        let env = Env::new(vec![Ok(Some(window("8", 11)))]);
        assert!(matches!(
            paste_into(&env, &request(Some("7"))),
            Err(PasteError::FocusChanged)
        ));
        assert!(env.sent.borrow().is_empty());
    }

    #[test]
    fn focus_that_never_returns_times_out() {
        let env = Env::new(vec![Ok(None)]);
        assert!(matches!(
            paste_into(&env, &request(Some("7"))),
            Err(PasteError::FocusTimeout)
        ));
        assert_eq!(env.polls.get(), 15);
        assert!(env.sent.borrow().is_empty());
        let own = Env::new(vec![Ok(Some(window("own", 4242)))]);
        assert!(matches!(
            paste_into(&own, &request(Some("7"))),
            Err(PasteError::FocusTimeout)
        ));
    }

    #[test]
    fn ipc_failure_is_reported_not_ignored() {
        let env = Env::new(vec![Err(CompositorError::Io("socket closed".into()))]);
        assert!(matches!(
            paste_into(&env, &request(Some("7"))),
            Err(PasteError::FocusUnverifiable(m)) if m.contains("socket closed")
        ));
        assert!(env.sent.borrow().is_empty());
    }

    #[test]
    fn clipboard_change_and_cancellation_stop_the_paste() {
        let env = Env::new(vec![Ok(Some(window("7", 10)))]);
        env.revision.set(Some(2));
        let mut r = request(Some("7"));
        r.clipboard_revision = Some(1);
        assert!(matches!(
            paste_into(&env, &r),
            Err(PasteError::ClipboardChanged)
        ));
        r.clipboard_revision = Some(2);
        assert!(paste_into(&env, &r).is_ok());
        env.cancelled.set(true);
        assert!(matches!(paste_into(&env, &r), Err(PasteError::Cancelled)));
        assert_eq!(env.sent.borrow().len(), 1);
    }

    #[test]
    fn without_a_target_the_paste_is_blind_and_says_so() {
        let env = Env::new(vec![]);
        let outcome = paste_into(&env, &request(None)).unwrap();
        assert_eq!(
            outcome,
            PasteOutcome::Sent {
                focus_verified: false
            }
        );
        assert_eq!(env.polls.get(), 0);
        assert_eq!(env.slept.get(), Duration::from_millis(370));
    }

    #[test]
    fn tool_failure_is_returned() {
        let mut env = Env::new(vec![Ok(Some(window("7", 10)))]);
        env.send_fails = true;
        assert!(matches!(
            paste_into(&env, &request(Some("7"))),
            Err(PasteError::Failed("wtype", _))
        ));
    }
}
