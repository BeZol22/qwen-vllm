---
name: secureboot-mok-blocks-nvidia-dkms
description: Secure Boot is ON on this box and NVIDIA driver upgrades that fall back to DKMS sign with an unenrolled MOK, so the GPU silently vanishes after reboot
metadata:
  node_type: memory
  type: project
  modified: 2026-09-18T22:30:00.000Z
---

`nvidia-smi` reporting "couldn't communicate with the NVIDIA driver" on this box is
usually **not** a driver bug. Secure Boot is **enabled**, kernel lockdown is
`integrity` and `/sys/module/module/parameters/sig_enforce` is `Y`. The tell is in
`journalctl -b 0 -k` (NOT `dmesg` -- `kernel.dmesg_restrict=1` hides it from the
user): `Loading of module with unavailable key is rejected`.

**What happened 2026-09-18 22:13.** Upgrading 595.71.05 -> **610.57.04-open** built
cleanly via DKMS (exit 0, 13 s) and signed `nvidia.ko` with a MOK key pair that the
upgrade had **generated seconds earlier** at `/var/lib/shim-signed/mok/MOK.{der,priv}`.
That key was never enrolled -- `mokutil --list-enrolled` showed only Canonical's CA,
`mokutil --list-new` was empty (no pending enrollment), and
`mokutil --test-key /var/lib/shim-signed/mok/MOK.der` said "is not enrolled". After
the 22:17 reboot there was no `/dev/nvidia0` (only the stub `/dev/nvidiactl`), no
`nvidia` in `lsmod`, and `nvidia-cdi-refresh.service` hit its restart limit. Every
nvidia package was `ii` and the module file was present and signed -- one missing key
enrollment was the entire fault.

**Why it never bit before:** 595 was installed as the Canonical **pre-signed**
`linux-modules-nvidia-595-open-7.0.0-22-generic` (no DKMS, no MOK). Canonical has
**no pre-signed 610 build for kernel 7.0.0-22** -- their 610 modules start at
7.0.0-31 -- so the 610 upgrade fell back to DKMS + local signing silently.

**How to apply:** diagnose with `journalctl -b 0 -k | grep -i "unavailable key"`,
`mokutil --sb-state` and `mokutil --test-key /var/lib/shim-signed/mok/MOK.der`
before touching vLLM, CUDA or [[nightly-cuda-toolchain-must-be-coherent]]. Fix by
enrolling the key once -- `sudo mokutil --import /var/lib/shim-signed/mok/MOK.der`,
reboot, then the blue MokManager screen (Enroll MOK -> Continue -> Yes -> password).
Requires physical console; it cannot be done over SSH. Once enrolled, every later
DKMS rebuild is signed with the same key. Alternatives: move to kernel 7.0.0-31 +
`linux-modules-nvidia-610-open-generic` (no MOK ever, but swaps the kernel the fp8
stack is measured on), or disable Secure Boot in BIOS.

The 610 upgrade was wanted for a reason -- driver 595.71.05 refuses to JIT CUDA 13.4
PTX ISA 9.4, which is what blocks the vision tower in
[[qwen38-nvfp4-full-context-port]].
