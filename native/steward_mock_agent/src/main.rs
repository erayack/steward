use anyhow::{anyhow, Context, Result};
use rand::Rng;
use serde_json::{json, Value};
use std::env;
use std::io::{self, BufRead, BufReader, Write};
use std::process;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

#[derive(Clone)]
struct Emitter {
    out: Arc<Mutex<io::Stdout>>,
}

impl Emitter {
    fn new() -> Self {
        Self {
            out: Arc::new(Mutex::new(io::stdout())),
        }
    }

    fn emit(&self, kind: &str, level: &str, fields: Value) -> Result<()> {
        let ts = OffsetDateTime::now_utc()
            .format(&Rfc3339)
            .context("format timestamp")?;

        let envelope = json!({
            "ts": ts,
            "level": level,
            "kind": kind,
            "fields": fields
        });

        let mut out = self
            .out
            .lock()
            .map_err(|_| anyhow!("stdout lock poisoned"))?;
        writeln!(out, "{envelope}")?;
        out.flush()?;
        Ok(())
    }
}

fn maybe_crash(enabled: bool, process_id: &str) {
    if !enabled {
        return;
    }

    let mut rng = rand::thread_rng();
    if rng.gen_ratio(1, 12) {
        eprintln!("{process_id}: crash injection triggered");
        process::exit(17);
    }
}

fn parse_action(command: &Value) -> String {
    command
        .get("fields")
        .and_then(|fields| fields.get("action"))
        .and_then(Value::as_str)
        .unwrap_or("unknown_action")
        .to_string()
}

fn parse_duration_ms(command: &Value) -> u64 {
    let requested = command
        .get("fields")
        .and_then(|fields| fields.get("duration_ms"))
        .and_then(Value::as_u64)
        .unwrap_or(300);

    requested.clamp(50, 5_000)
}

fn handle_command(
    line: &str,
    emitter: &Emitter,
    process_id: &str,
    crash_mode: bool,
    seq: &Arc<AtomicU64>,
) -> Result<()> {
    let command: Value = serde_json::from_str(line).context("decode command JSON")?;
    let kind = command
        .get("kind")
        .and_then(Value::as_str)
        .unwrap_or("event");

    if kind != "command" {
        return Ok(());
    }

    let action = parse_action(&command);
    let duration_ms = parse_duration_ms(&command);
    let start_seq = seq.fetch_add(1, Ordering::Relaxed) + 1;

    emitter.emit(
        "event",
        "info",
        json!({
            "process_id": process_id,
            "seq": start_seq,
            "phase": "start",
            "action": action,
            "duration_ms": duration_ms
        }),
    )?;

    thread::sleep(Duration::from_millis(duration_ms));

    let end_seq = seq.fetch_add(1, Ordering::Relaxed) + 1;
    emitter.emit(
        "event",
        "info",
        json!({
            "process_id": process_id,
            "seq": end_seq,
            "phase": "finish",
            "action": action,
            "result": "ok"
        }),
    )?;

    maybe_crash(crash_mode, process_id);
    Ok(())
}

fn run_heartbeat_loop(
    emitter: Emitter,
    process_id: String,
    crash_mode: bool,
    seq: Arc<AtomicU64>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || loop {
        let heartbeat_seq = seq.fetch_add(1, Ordering::Relaxed) + 1;
        if let Err(err) = emitter.emit(
            "heartbeat",
            "info",
            json!({
                "process_id": process_id,
                "seq": heartbeat_seq
            }),
        ) {
            eprintln!("heartbeat emit failed: {err:?}");
            process::exit(2);
        }

        maybe_crash(crash_mode, &process_id);
        thread::sleep(Duration::from_secs(5));
    })
}

fn main() -> Result<()> {
    let process_id =
        env::var("STEWARD_MOCK_PROCESS_ID").unwrap_or_else(|_| "mock_agent".to_string());
    let crash_mode = env::var("STEWARD_MOCK_CRASH_MODE")
        .map(|value| value == "1")
        .unwrap_or(false);

    let emitter = Emitter::new();
    let seq = Arc::new(AtomicU64::new(0));
    let _heartbeat = run_heartbeat_loop(
        emitter.clone(),
        process_id.clone(),
        crash_mode,
        Arc::clone(&seq),
    );

    emitter.emit(
        "event",
        "info",
        json!({
            "process_id": process_id,
            "phase": "started"
        }),
    )?;

    let stdin = io::stdin();
    let reader = BufReader::new(stdin.lock());

    for line_result in reader.lines() {
        let line = line_result.context("read stdin line")?;
        let trimmed = line.trim();

        if trimmed.is_empty() {
            continue;
        }

        if let Err(err) = handle_command(trimmed, &emitter, &process_id, crash_mode, &seq) {
            let error_seq = seq.fetch_add(1, Ordering::Relaxed) + 1;
            let _ = emitter.emit(
                "error",
                "error",
                json!({
                    "process_id": process_id,
                    "seq": error_seq,
                    "message": err.to_string()
                }),
            );
        }
    }

    Ok(())
}
