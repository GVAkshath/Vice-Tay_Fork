//! The console's audio DSP (`chad.dll`): streams that convolve blocks of
//! float samples with an impulse response (reverb), or run other block
//! transforms, on a coprocessor.
//!
//! A title connects once with a memory block for the DSP, activates
//! streams, and submits one command per block (gains, an input and an
//! output buffer). Activation hands back a status block whose second word is
//! the ticket of the last completed command and whose fourth is its result;
//! the title checks it one block later and treats a late command as an
//! overrun. Commands complete when submitted here.
//!
//! The transforms themselves are not computed: the hardware takes impulse
//! responses already in its own partitioned frequency-domain layout, which
//! is not known. The default output is silence. `VICTORY_DSP_MONO_PASSTHROUGH=1`
//! enables a dry output for mono blocks, at unity gain.
#![allow(non_snake_case)]
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::ffi::c_void;
use std::sync::{LazyLock, Mutex};

use super::xasync::E_INVALIDARG;
use super::xgameruntime::{HRESULT, S_OK};
use crate::{HleModule, hle_export};

const E_POINTER: HRESULT = 0x8000_4003_u32 as i32;
const E_OUTOFMEMORY: HRESULT = 0x8007_000E_u32 as i32;

const CONVOLUTION: u32 = 1;
/// Option bits that need a stereo stream, and one convolution refuses.
const STEREO_OPTIONS: u32 = 2 | 8;
const NOT_FOR_CONVOLUTION: u32 = 4;

static MONO_PASSTHROUGH: LazyLock<bool> = LazyLock::new(|| {
    std::env::var_os("VICTORY_DSP_MONO_PASSTHROUGH").is_some_and(|value| value == "1")
});

pub struct Dsp {
    max_streams: u32,
    active: Mutex<u32>,
}

/// What activation describes.
#[repr(C, packed)]
pub struct StreamDesc {
    kind: u32,
    options: u32,
    frames: u32,
    channels: u32,
    ir_floats: u32,
    ir: *const f32,
}

/// The status block a stream's owner polls.
#[repr(C)]
pub struct Status {
    submitted: u32,
    completed: u32,
    reserved: u32,
    result: HRESULT,
}

pub struct Stream {
    dsp: *mut Dsp,
    frames: u32,
    channels: u32,
    status: Box<Status>,
}

/// One block of work.
#[repr(C)]
pub struct Command {
    gains: [f32; 2],
    input: *const f32,
    output: *mut f32,
    reserved: u64,
}

pub extern "system" fn XDspConnectWithMaximumStreamLimit(
    base: *mut c_void,
    base_length: u32,
    ir_seconds: u32,
    max_streams: u32,
    max_channels: u32,
    out: *mut *mut Dsp,
) -> HRESULT {
    if base.is_null()
        || !(0x1_0000..=0x1F40_0000).contains(&base_length)
        || ir_seconds > 0x80
        || max_streams > 0x100
        || max_channels > 2
    {
        return E_INVALIDARG;
    }
    if out.is_null() {
        return E_POINTER;
    }
    tracing::info!(
        base_length,
        ir_seconds,
        max_streams,
        max_channels,
        "audio DSP connected"
    );
    let dsp = Box::new(Dsp {
        max_streams,
        active: Mutex::new(0),
    });
    // SAFETY: checked non-null.
    unsafe { out.write(Box::into_raw(dsp)) };
    S_OK
}

pub extern "system" fn XDspDisconnect(dsp: *mut Dsp) -> HRESULT {
    if dsp.is_null() {
        return E_INVALIDARG;
    }
    // SAFETY: made by `XDspConnectWithMaximumStreamLimit`; disconnected
    // once, after its streams.
    drop(unsafe { Box::from_raw(dsp) });
    S_OK
}

fn valid(desc: &StreamDesc) -> bool {
    let (kind, options, frames, channels) = (desc.kind, desc.options, desc.frames, desc.channels);
    let shape = if kind == CONVOLUTION {
        (1..=2).contains(&channels)
            && matches!(frames, 0x200 | 0x400)
            && options & NOT_FOR_CONVOLUTION == 0
    } else {
        channels == 1 && matches!(frames, 0x200 | 0x400 | 0x800)
    };
    shape && (options & STEREO_OPTIONS == 0 || channels == 2)
}

pub extern "system" fn XDspActivate(
    dsp: *mut Dsp,
    desc: *const StreamDesc,
    status: *mut *const Status,
    stream: *mut *mut Stream,
) -> HRESULT {
    if status.is_null() || stream.is_null() {
        return E_POINTER;
    }
    if dsp.is_null() || desc.is_null() {
        return E_INVALIDARG;
    }
    // SAFETY: checked non-null; the title passes its description.
    let desc = unsafe { &*desc };
    if !valid(desc) {
        return E_INVALIDARG;
    }
    let (kind, options, frames, channels) = (desc.kind, desc.options, desc.frames, desc.channels);
    tracing::debug!(
        kind,
        options,
        frames,
        channels,
        "audio DSP stream activated"
    );
    {
        // SAFETY: a connection from `XDspConnectWithMaximumStreamLimit`.
        let dsp = unsafe { &*dsp };
        let mut active = dsp.active.lock().unwrap_or_else(|e| e.into_inner());
        if *active >= dsp.max_streams {
            return E_OUTOFMEMORY;
        }
        *active += 1;
    }
    let new = Box::new(Stream {
        dsp,
        frames: desc.frames,
        channels: desc.channels,
        status: Box::new(Status {
            submitted: 0,
            completed: 0,
            reserved: 0,
            result: S_OK,
        }),
    });
    // SAFETY: checked non-null.
    unsafe {
        status.write(&*new.status);
        stream.write(Box::into_raw(new));
    }
    S_OK
}

pub extern "system" fn XDspDeactivate(stream: *mut Stream) -> HRESULT {
    if stream.is_null() {
        return E_INVALIDARG;
    }
    // SAFETY: made by `XDspActivate`; deactivated once.
    let stream = unsafe { Box::from_raw(stream) };
    // SAFETY: the connection outlives its streams.
    let dsp = unsafe { &*stream.dsp };
    *dsp.active.lock().unwrap_or_else(|e| e.into_inner()) -= 1;
    S_OK
}

#[cfg(windows)]
fn copy_mono_input(command: &Command, samples: usize) -> bool {
    use windows_sys::Win32::System::Diagnostics::Debug::ReadProcessMemory;
    use windows_sys::Win32::System::Threading::GetCurrentProcess;

    // One valid mono stream block. Stage the read before touching the output
    // so overlapping buffers and a failed or partial read are safe.
    let mut block = [0.0f32; 0x800];
    if samples > block.len() {
        return false;
    }
    let bytes = samples * size_of::<f32>();
    let mut copied = 0;
    // SAFETY: the destination is a live scratch buffer of at least bytes.
    // The OS reads only from this process and reports inaccessible input.
    let read = unsafe {
        ReadProcessMemory(
            GetCurrentProcess(),
            command.input.cast(),
            block.as_mut_ptr().cast(),
            bytes,
            &mut copied,
        )
    };
    if read == 0 || copied != bytes {
        return false;
    }
    // SAFETY: the title's output buffer holds one block of the stream.
    unsafe { std::ptr::copy(block.as_ptr(), command.output, samples) };
    true
}

#[cfg(not(windows))]
fn copy_mono_input(_command: &Command, _samples: usize) -> bool {
    false
}

fn write_output(stream: &Stream, command: &Command, dry: bool) {
    if command.output.is_null() {
        return;
    }
    let samples = (stream.frames * stream.channels) as usize;
    if dry && stream.channels == 1 && !command.input.is_null() && copy_mono_input(command, samples) {
        return;
    }
    // SAFETY: the title's output buffer holds one block of the stream.
    unsafe { std::ptr::write_bytes(command.output, 0, samples) };
}

/// Completes the command and publishes its status.
pub extern "system" fn XDspSubmitCommand(
    stream: *mut Stream,
    command: *const Command,
    ticket: *mut u32,
) -> HRESULT {
    if stream.is_null() || command.is_null() {
        return E_INVALIDARG;
    }
    // SAFETY: a stream from `XDspActivate`, the title's command.
    let (stream, command) = unsafe { (&mut *stream, &*command) };
    write_output(stream, command, *MONO_PASSTHROUGH);
    let status = &mut *stream.status;
    let next = status.submitted.wrapping_add(1);
    // SAFETY: the status block is read by title code on other threads.
    unsafe {
        std::ptr::write_volatile(&mut status.submitted, next);
        std::ptr::write_volatile(&mut status.result, S_OK);
        std::ptr::write_volatile(&mut status.completed, next);
    }
    if !ticket.is_null() {
        // SAFETY: optional out parameter.
        unsafe { ticket.write(next) };
    }
    S_OK
}

pub(crate) fn module() -> HleModule {
    HleModule {
        name: "dsp",
        dlls: &["chad.dll"],
        exports: vec![
            hle_export!(XDspConnectWithMaximumStreamLimit),
            hle_export!(XDspDisconnect),
            hle_export!(XDspActivate),
            hle_export!(XDspDeactivate),
            hle_export!(XDspSubmitCommand),
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(windows)]
    #[test]
    fn mono_passthrough_copies_one_block_and_preserves_the_silence_fallback() {
        let mut stream = Stream {
            dsp: std::ptr::null_mut(),
            frames: 0x200,
            channels: 1,
            status: Box::new(Status {
                submitted: 0,
                completed: 0,
                reserved: 0,
                result: S_OK,
            }),
        };
        let input = [0.25f32; 0x200];
        let mut output = [1.0f32; 0x400];
        let mut command = Command {
            gains: [1.0; 2],
            input: input.as_ptr(),
            output: output.as_mut_ptr(),
            reserved: 0,
        };
        write_output(&stream, &command, true);
        assert_eq!(&output[..0x200], &input);
        assert!(output[0x200..].iter().all(|&sample| sample == 1.0));

        command.input = output.as_ptr();
        write_output(&stream, &command, true);
        assert_eq!(&output[..0x200], &input);

        write_output(&stream, &command, false);
        assert!(output[..0x200].iter().all(|&sample| sample == 0.0));
        output.fill(1.0);
        command.input = std::ptr::null();
        write_output(&stream, &command, true);
        assert!(output[..0x200].iter().all(|&sample| sample == 0.0));

        output.fill(1.0);
        stream.channels = 2;
        command.input = input.as_ptr();
        write_output(&stream, &command, true);
        assert!(output.iter().all(|&sample| sample == 0.0));
    }

    #[test]
    fn convolution_stream_as_the_title_drives_it() {
        let mut base = vec![0u8; 0x10_0000];
        let mut dsp = std::ptr::null_mut();
        assert_eq!(
            XDspConnectWithMaximumStreamLimit(
                base.as_mut_ptr().cast(),
                0x10_0000,
                24,
                0x80,
                1,
                &mut dsp
            ),
            S_OK
        );
        let ir = vec![0f32; 0x800];
        // Stereo convolution with option 2, as the title asks for.
        let desc = StreamDesc {
            kind: CONVOLUTION,
            options: 2,
            frames: 0x400,
            channels: 2,
            ir_floats: 0x800,
            ir: ir.as_ptr(),
        };
        let (mut status, mut stream) = (std::ptr::null(), std::ptr::null_mut());
        assert_eq!(XDspActivate(dsp, &desc, &mut status, &mut stream), S_OK);
        let mut output = vec![1f32; 0x800];
        let input = vec![0.5f32; 0x800];
        let command = Command {
            gains: [1.0, 1.0],
            input: input.as_ptr(),
            output: output.as_mut_ptr(),
            reserved: 0,
        };
        let mut ticket = 0;
        assert_eq!(XDspSubmitCommand(stream, &command, &mut ticket), S_OK);
        // SAFETY: the stream's status block.
        let (completed, result) = unsafe { ((*status).completed, (*status).result) };
        assert_eq!((completed, result), (ticket, S_OK));
        assert!(output.iter().all(|&s| s == 0.0));
        assert_eq!(XDspDeactivate(stream), S_OK);

        // Mono streams refuse stereo options; transforms are mono only.
        let bad = StreamDesc {
            channels: 1,
            ..desc
        };
        assert_eq!(
            XDspActivate(dsp, &bad, &mut status, &mut stream),
            E_INVALIDARG
        );
        let transform = StreamDesc {
            kind: 2,
            options: 0,
            channels: 1,
            ir_floats: 0,
            ir: std::ptr::null(),
            ..desc
        };
        assert_eq!(
            XDspActivate(dsp, &transform, &mut status, &mut stream),
            S_OK
        );
        assert_eq!(XDspDeactivate(stream), S_OK);
        assert_eq!(XDspDisconnect(dsp), S_OK);
    }
}
