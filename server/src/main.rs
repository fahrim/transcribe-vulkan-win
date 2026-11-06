//! A small HTTP server around transcribe.cpp, built to serve whisperlane's
//! multilingual speech-model families (Qwen3-ASR first).
//!
//! It speaks the parts of `whisper-server` the supervisor relies on:
//!
//!   * arguments `--model --host --port --language`
//!   * `GET /` answers 200 (the readiness ping)
//!   * `POST /inference` and `POST /v1/audio/transcriptions` take a multipart
//!     body (`file`, `language`, `response_format=json`) and answer
//!     `{"text": "..."}`
//!   * the startup line states the backend that actually bound the model,
//!     because transcribe.cpp prints no device banner of its own
//!
//! One session, one request at a time, loopback only. The supervisor
//! guarantees that shape.
//!
//! Engine sources: transcribe.cpp (MIT). Server code: MIT.

use std::io::Read;
use std::path::PathBuf;
use std::sync::Mutex;

use transcribe_cpp::{Model, RunOptions, Session};
use tiny_http::{Header, Method, Response, Server};

const ENGINE_SAMPLE_RATE: u32 = 16_000;
const MAX_BODY: usize = 64 * 1024 * 1024;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut model_path: Option<PathBuf> = None;
    let mut host = String::from("127.0.0.1");
    let mut port = 8811u16;
    let mut language: Option<String> = None;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--model" => model_path = args.next().map(PathBuf::from),
            "--host" => host = args.next().unwrap_or(host),
            "--port" => port = args.next().and_then(|p| p.parse().ok()).unwrap_or(port),
            "--language" => language = args.next().filter(|l| l != "auto"),
            other => {
                eprintln!("transcribe-server: unknown argument {other}");
                std::process::exit(2);
            }
        }
    }

    let model_path = model_path.ok_or("--model is required (path to a GGUF file)")?;
    if !model_path.is_file() {
        return Err(format!("model not found: {}", model_path.display()).into());
    }

    transcribe_cpp::init_logging();
    transcribe_cpp::init_backends_default()
        .map_err(|e| format!("could not initialize backends: {e}"))?;

    let load_started = std::time::Instant::now();
    let model = Model::load(&model_path)
        .map_err(|e| format!("could not load {}: {e}", model_path.display()))?;
    let session = model
        .session()
        .map_err(|e| format!("could not open a session: {e}"))?;

    // The supervisor reads this line as proof of the backend that actually
    // served, exactly as it reads whisper.cpp's device banner.
    let backend = backend_name(&model.backend());
    let device = model
        .device()
        .ok()
        .map(|device| device.description)
        .filter(|description| !description.is_empty())
        .unwrap_or_else(|| "unknown".into());
    eprintln!(
        "transcribe-server backend={} device=\"{}\" arch={} model=\"{}\" load_ms={}",
        backend,
        device,
        model.arch(),
        model_path.display(),
        load_started.elapsed().as_millis()
    );

    let state = Mutex::new(ServerState { session, language });

    let address = format!("{host}:{port}");
    let server = Server::http(&address).map_err(|e| format!("could not bind {address}: {e}"))?;
    eprintln!("transcribe-server listening on http://{address}");

    for mut request in server.incoming_requests() {
        let url = request.url().to_string();
        let is_post = matches!(request.method(), Method::Post);
        let is_inference =
            url.starts_with("/inference") || url.starts_with("/v1/audio/transcriptions");

        if !is_post {
            // `GET /` is the readiness ping. Any GET answers 200, matching
            // whisper-server's root answer.
            let _ = request.respond(Response::from_string("ok").with_status_code(200));
            continue;
        }
        if !is_inference {
            let _ = request.respond(Response::from_string("not found").with_status_code(404));
            continue;
        }

        match handle_inference(&mut request, &state) {
            Ok(text) => {
                let body = serde_json::json!({ "text": text }).to_string();
                let mut response = Response::from_string(body).with_status_code(200);
                response.add_header(
                    Header::from_bytes("Content-Type", "application/json")
                        .expect("static header"),
                );
                eprintln!(
                    "transcribe-server inference ok text_chars={}",
                    text.chars().count()
                );
                let _ = request.respond(response);
            }
            Err(error) => {
                eprintln!("transcribe-server inference failed: {error}");
                let body = serde_json::json!({ "error": error.to_string() }).to_string();
                let mut response = Response::from_string(body).with_status_code(500);
                response.add_header(
                    Header::from_bytes("Content-Type", "application/json")
                        .expect("static header"),
                );
                let _ = request.respond(response);
            }
        }
    }

    Ok(())
}

/// `model.backend()` is a free-form string such as `Vulkan0` or `CPU`; the
/// supervisor needs one of a few names.
fn backend_name(raw: &str) -> &'static str {
    let lower = raw.to_lowercase();
    if lower.starts_with("vulkan") {
        "vulkan"
    } else if lower.starts_with("cuda") {
        "cuda"
    } else if lower.starts_with("rocm") {
        "rocm"
    } else if lower.starts_with("metal") {
        "metal"
    } else {
        "cpu"
    }
}

struct ServerState {
    session: Session,
    language: Option<String>,
}

fn handle_inference(
    request: &mut tiny_http::Request,
    state: &Mutex<ServerState>,
) -> Result<String, Box<dyn std::error::Error>> {
    let content_type = request
        .headers()
        .iter()
        .find(|h| h.field.equiv("Content-Type"))
        .map(|h| h.value.as_str().to_string())
        .ok_or("missing Content-Type")?;
    let boundary = content_type
        .split(';')
        .find_map(|part| part.trim().strip_prefix("boundary="))
        .map(|b| b.trim_matches('"').to_string())
        .ok_or("multipart body has no boundary")?;

    let mut body = Vec::new();
    request
        .as_reader()
        .take(MAX_BODY as u64)
        .read_to_end(&mut body)?;

    let parts = parse_multipart(&body, &boundary)?;
    let mut wav_bytes: Option<Vec<u8>> = None;
    let mut language: Option<String> = None;
    let mut response_format: Option<String> = None;
    for part in parts {
        match part.name.as_str() {
            "file" => wav_bytes = Some(part.body),
            "language" => {
                let value = String::from_utf8_lossy(&part.body).trim().to_string();
                if !value.is_empty() && value != "auto" {
                    language = Some(value);
                }
            }
            "response_format" => {
                response_format = Some(String::from_utf8_lossy(&part.body).trim().to_string());
            }
            _ => {}
        }
    }
    if let Some(format) = &response_format {
        if format != "json" && format != "verbose_json" {
            return Err(format!("unsupported response_format: {format}").into());
        }
    }

    let wav_bytes = wav_bytes.ok_or("multipart body has no `file` part")?;
    let pcm = decode_wav_mono_16k(&wav_bytes)?;

    let mut guard = state.lock().map_err(|_| "session lock poisoned")?;
    let hint = language.or_else(|| guard.language.clone());
    let started = std::time::Instant::now();
    let result = guard
        .session
        .run(
            &pcm,
            &RunOptions {
                language: hint,
                ..Default::default()
            },
        )
        .map_err(|e| format!("transcription failed: {e}"))?;
    eprintln!(
        "transcribe-server run samples={} ms={} encode_ms={:.0} decode_ms={:.0} language={:?}",
        pcm.len(),
        started.elapsed().as_millis(),
        result.timings.encode_ms,
        result.timings.decode_ms,
        result.language
    );
    Ok(result.text.trim().to_string())
}

struct Part {
    name: String,
    body: Vec<u8>,
}

/// Minimal multipart/form-data parser: enough for the fields whisper-server
/// accepts. Splits on `--boundary` and reads part headers and bodies.
fn parse_multipart(body: &[u8], boundary: &str) -> Result<Vec<Part>, Box<dyn std::error::Error>> {
    let delimiter = format!("--{boundary}");
    let mut parts = Vec::new();
    let mut cursor = 0usize;
    let bytes = body;

    while let Some(start) = find_from(bytes, delimiter.as_bytes(), cursor) {
        let after_delim = start + delimiter.len();
        if bytes[after_delim..].starts_with(b"--") {
            break;
        }
        // Skip CRLF after the delimiter.
        let mut header_start = after_delim;
        if bytes.get(header_start..header_start + 2) == Some(b"\r\n") {
            header_start += 2;
        } else if bytes.get(header_start) == Some(&b'\n') {
            header_start += 1;
        } else {
            break;
        }
        let Some(header_end) = find_from(bytes, b"\r\n\r\n", header_start) else {
            break;
        };
        let headers = &bytes[header_start..header_end];
        let body_start = header_end + 4;
        let Some(body_end) = find_from(bytes, format!("\r\n--{boundary}").as_bytes(), body_start)
        else {
            break;
        };

        let name = header_name(headers).ok_or("multipart part has no name")?;
        parts.push(Part {
            name,
            body: bytes[body_start..body_end].to_vec(),
        });
        cursor = body_end + 2;
    }
    Ok(parts)
}

fn header_name(headers: &[u8]) -> Option<String> {
    let text = String::from_utf8_lossy(headers);
    for line in text.split("\r\n") {
        if line.to_ascii_lowercase().starts_with("content-disposition:") {
            for piece in line.split(';').skip(1) {
                let piece = piece.trim();
                // `filename=` also contains `name=`; only `name=` counts.
                if piece.starts_with("filename=") {
                    continue;
                }
                if let Some(value) = piece.strip_prefix("name=") {
                    return Some(value.trim_matches('"').to_string());
                }
            }
        }
    }
    None
}

fn find_from(haystack: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if needle.is_empty() || from >= haystack.len() {
        return None;
    }
    haystack[from..]
        .windows(needle.len())
        .position(|window| window == needle)
        .map(|pos| pos + from)
}

/// Decodes a WAV into 16 kHz mono f32, mixing channels and resampling linearly.
fn decode_wav_mono_16k(bytes: &[u8]) -> Result<Vec<f32>, Box<dyn std::error::Error>> {
    let mut reader = hound::WavReader::new(std::io::Cursor::new(bytes))?;
    let spec = reader.spec();
    let channels = usize::from(spec.channels.max(1));
    let samples: Vec<f32> = match (spec.sample_format, spec.bits_per_sample) {
        (hound::SampleFormat::Int, bits) if bits <= 16 => reader
            .samples::<i16>()
            .map(|s| s.map(|v| v as f32 / i16::MAX as f32))
            .collect::<Result<Vec<_>, _>>()?,
        (hound::SampleFormat::Int, _) => reader
            .samples::<i32>()
            .map(|s| s.map(|v| v as f32 / i32::MAX as f32))
            .collect::<Result<Vec<_>, _>>()?,
        (hound::SampleFormat::Float, _) => reader
            .samples::<f32>()
            .collect::<Result<Vec<_>, _>>()?,
    };
    let mono: Vec<f32> = samples
        .chunks(channels)
        .map(|frame| frame.iter().sum::<f32>() / frame.len() as f32)
        .collect();
    Ok(resample_linear(&mono, spec.sample_rate, ENGINE_SAMPLE_RATE))
}

fn resample_linear(samples: &[f32], from_rate: u32, to_rate: u32) -> Vec<f32> {
    if samples.is_empty() || from_rate == 0 || to_rate == 0 {
        return Vec::new();
    }
    if from_rate == to_rate {
        return samples.to_vec();
    }
    let ratio = from_rate as f64 / to_rate as f64;
    let out_len = (samples.len() as f64 / ratio).ceil() as usize;
    (0..out_len)
        .map(|i| {
            let pos = i as f64 * ratio;
            let lo = pos.floor() as usize;
            let hi = (lo + 1).min(samples.len() - 1);
            let frac = (pos - lo as f64) as f32;
            samples[lo] * (1.0 - frac) + samples[hi] * frac
        })
        .collect()
}
