#!/usr/bin/env python3
"""Enable --kv-cache-dtype nvfp4 on consumer Blackwell (RTX 5090, SM120) in the
vllm-nightly-env wheel.

WHY THIS EXISTS
  Qwen3.8-27B's native 262144 context does not fit on 32 GB at fp8 KV: vLLM puts
  the need at 9.13 GiB against a ~7.9 GiB hard ceiling. NVFP4 KV is 18.00
  KiB/token => 4.50 GiB at 262144, which fits with room to spare. Upstream vLLM
  already carries the whole NVFP4 KV machinery AND the XQA-on-SM12x decode
  infrastructure, and FlashInfer 0.6.18's xqa_batch_decode_with_kv_cache already
  accepts kv_cache_sf / q_len_per_req / q_cu_seq_lens. The ONLY thing missing is
  the routing: upstream still gates nvfp4 KV to SM100 + trtllm-gen, because
  consumer Blackwell has no trtllm-gen FP4 FMHA.

  This is the ch2lab/vllm `sm120-nvfp4-kv-cache` work (commit 8275b36, 2026-08-18)
  ported onto the much newer nightly (0.29.1rc1.dev371+g1cdf1689e) rather than
  built from that Aug snapshot -- building the fork would throw away ~370 dev
  commits, needs a full CUDA compile, and carries 2-GPU PP/MTP2 changes we do not
  want (its run2.sh uses VLLM_PP_LAYER_PARTITION=38,26).

DELIBERATELY NOT PORTED
  The fork's VO-split machinery (_vo_split_factor, VLLM_NVFP4_KV_VOSPLIT, the
  two-pass narrow()/copy_() run helper). That exists only because the FA2 nvfp4
  kernel caps HEAD_DIM_VO at 256 and Gemma 4's global layers are 512 wide.
  _vo_split_factor() returns 1 for head_size <= 256, and Qwen3.8's head_dim IS
  256, so every one of those code paths is inert here. Porting it would add ~120
  lines of untestable-on-this-box code. If you ever run a head_size > 256 model
  with nvfp4 KV, port it then.

Idempotent. Re-run after every `pip install -U vllm` in the nightly env.
"""

import shutil
import sys
from pathlib import Path

TARGET = Path.home() / (
    "vllm-nightly-env/lib/python3.12/site-packages/vllm/"
    "v1/attention/backends/flashinfer.py"
)

MARKER = "sm120-nvfp4-kv-patch v4"


def sub(src: str, old: str, new: str, count: int, label: str) -> str:
    """Replace `old` exactly `count` times or abort."""
    found = src.count(old)
    if found != count:
        sys.exit(
            f"ABORT [{label}]: expected {count} occurrence(s) of anchor, found "
            f"{found}. Upstream has drifted -- re-read the file and update this "
            f"patch instead of forcing it.\n--- anchor ---\n{old}"
        )
    return src.replace(old, new)


def main() -> None:
    if not TARGET.exists():
        sys.exit(f"ABORT: {TARGET} does not exist.")

    src = TARGET.read_text()

    if MARKER in src:
        print(f"Already patched ({MARKER}); nothing to do.")
        return

    backup = TARGET.with_suffix(".py.orig")
    if backup.exists():
        # A previous revision of this patch is applied. Re-apply from the
        # pristine copy rather than patching patched code.
        src = backup.read_text()
        print(f"Re-applying from {backup}")
    else:
        shutil.copy2(TARGET, backup)
        print(f"Backed up original -> {backup}")

    # ---- 1. FlashInferBackend.supports_kv_cache_dtype -----------------------
    # The admission gate. Without this, vLLM rejects --kv-cache-dtype nvfp4 on
    # SM120 before anything else runs.
    src = sub(
        src,
        """        if kv_cache_dtype is not None and kv_cache_dtype.startswith("nvfp4"):
            return (
                current_platform.is_device_capability_family(100)
                and supports_trtllm_attention(is_prefill=True)
                and supports_trtllm_attention(is_prefill=False)
            )""",
        """        if kv_cache_dtype is not None and kv_cache_dtype.startswith("nvfp4"):
            # Consumer Blackwell (sm120/sm121): NVFP4 KV is served through the
            # FlashInfer FA2 paged reader / XQA decode (uint8 fp4 cache), which
            # needs no trtllm-gen FP4 FMHA. Mirrors the builder __init__ gate.
            if current_platform.is_device_capability_family(120):
                return True
            return (
                current_platform.is_device_capability_family(100)
                and supports_trtllm_attention(is_prefill=True)
                and supports_trtllm_attention(is_prefill=False)
            )""",
        1,
        "supports_kv_cache_dtype",
    )

    # ---- 2. FlashInferBackend.supported_kv_cache_layouts -------------------
    # NVFP4 packs [data | scale] regions inside each K/V side's byte range
    # (reshape_and_cache_nvfp4 writes scales at side_base + num_heads *
    # block_size * data_dim; nvfp4_split_data_scale reads them back with derived
    # strides). That carve is only byte-coherent when each side's heads own one
    # contiguous region per page, i.e. head-major. Under a token-major layout the
    # K and V head rows interleave and the side offsets land inside the other
    # side's data -> SILENT KV CORRUPTION, so constrain it here.
    src = sub(
        src,
        """        capability = current_platform.get_device_capability()
        if capability is not None and capability.major == 10:
            # The trtllm-gen kernels consume head-major block interiors; the L/B
            # nesting outside the block is immaterial to them.
            return (KVCacheLayout.LBHNC, KVCacheLayout.BLHNC)
        return super().supported_kv_cache_layouts()""",
        """        capability = current_platform.get_device_capability()
        if capability is not None and capability.major == 10:
            # The trtllm-gen kernels consume head-major block interiors; the L/B
            # nesting outside the block is immaterial to them.
            return (KVCacheLayout.LBHNC, KVCacheLayout.BLHNC)
        if capability is not None and capability.major == 12:
            # sm120/sm121 NVFP4 KV needs the same head-major block interior: the
            # per-side [data | scale] carve is only byte-coherent when each
            # side's heads own one contiguous region per page. A token-major
            # layout would silently corrupt the cache rather than fail.
            vllm_config = get_current_vllm_config_or_none()
            if (
                vllm_config is not None
                and vllm_config.cache_config is not None
                and vllm_config.cache_config.cache_dtype.startswith("nvfp4")
            ):
                return (KVCacheLayout.LBHNC, KVCacheLayout.BLHNC)
        return super().supported_kv_cache_layouts()""",
        1,
        "supported_kv_cache_layouts",
    )

    # ---- 3. FlashInferMetadataBuilder.__init__ ------------------------------
    src = sub(
        src,
        """            self.is_kvcache_nvfp4 = self.cache_dtype.startswith("nvfp4")
            if self.is_kvcache_nvfp4:
                if (
                    force_use_trtllm_attention() is False
                    or not supports_trtllm_attention(is_prefill=True)
                    or not supports_trtllm_attention(is_prefill=False)
                ):
                    raise ValueError(
                        f"--kv-cache-dtype {self.cache_dtype} requires the "
                        "SM100 trtllm-gen "
                        "FlashInfer path."
                    )
                # The scale search only affects the store kernel. FlashInfer
                # reads both variants using the same NVFP4 layout.
                self.kv_cache_dtype = "nvfp4\"""",
        """            self.is_kvcache_nvfp4 = self.cache_dtype.startswith("nvfp4")
            self.use_fa2_nvfp4_kv = False
            if self.is_kvcache_nvfp4:
                if current_platform.is_device_capability_family(120):
                    # Consumer Blackwell (sm120/sm121): no trtllm-gen FP4 FMHA,
                    # so route NVFP4 KV through FlashInfer's FA2 paged reader
                    # (prefill) and XQA decode. The cache stores packed uint8
                    # fp4 data; the per-side [data | scale] regions are read
                    # back as views with explicit strides
                    # (nvfp4_split_data_scale), so the op dtype is uint8 rather
                    # than the "nvfp4" string the trtllm-gen path passes down.
                    self.use_fa2_nvfp4_kv = True
                    self.kv_cache_dtype = FlashInferBackend.get_dtype_for_flashinfer(
                        "nvfp4"
                    )
                elif (
                    force_use_trtllm_attention() is False
                    or not supports_trtllm_attention(is_prefill=True)
                    or not supports_trtllm_attention(is_prefill=False)
                ):
                    raise ValueError(
                        f"--kv-cache-dtype {self.cache_dtype} requires the "
                        "SM100 trtllm-gen FlashInfer path or consumer "
                        "Blackwell (sm120/sm121)."
                    )
                else:
                    # The scale search only affects the store kernel. FlashInfer
                    # reads both variants using the same NVFP4 layout.
                    self.kv_cache_dtype = "nvfp4\"""",
        1,
        "builder.__init__ nvfp4 gate",
    )

    src = sub(
        src,
        """            self.cache_dtype = "auto"
            self.is_kvcache_nvfp4 = False
            assert self.kv_cache_spec.dtype == self.model_config.dtype""",
        """            self.cache_dtype = "auto"
            self.is_kvcache_nvfp4 = False
            self.use_fa2_nvfp4_kv = False
            assert self.kv_cache_spec.dtype == self.model_config.dtype""",
        1,
        "builder.__init__ non-quant branch",
    )

    # ---- 4. Wrapper backend selection (prefill + decode) -------------------
    # Upstream hardwires trtllm-gen for nvfp4 ("fa2/fa3 do not support nvfp4"),
    # which is true of the trtllm-gen *swizzled* scale layout but not of the FA2
    # paged reader with linear scale factors that the sm12x cache writer stores.
    for indent, label in ((" " * 20, "prefill wrapper"), (" " * 12, "decode wrapper")):
        src = sub(
            src,
            f'{indent}backend = "trtllm-gen" if self.is_kvcache_nvfp4 else "auto"',
            (
                f"{indent}if self.use_fa2_nvfp4_kv:\n"
                f'{indent}    backend = "fa2"\n'
                f"{indent}elif self.is_kvcache_nvfp4:\n"
                f'{indent}    backend = "trtllm-gen"\n'
                f"{indent}else:\n"
                f'{indent}    backend = "auto"'
            ),
            1,
            label,
        )

    # ---- 5. Builder cudagraph/plan output dtype ----------------------------
    # "NVFP4 trtllm kernel only supports FP8 output" -- that is a trtllm-gen
    # constraint. The FA2/XQA path returns the model dtype, so planning the
    # wrapper for FP8 out would mismatch the buffer forward() actually passes.
    src = sub(
        src,
        "FP8_DTYPE if self.is_kvcache_nvfp4 else self.model_config.dtype",
        "FP8_DTYPE\n                        if self.is_kvcache_nvfp4 and not self.use_fa2_nvfp4_kv\n                        else self.model_config.dtype",
        2,
        "builder o_dtype",
    )

    # ---- 6. FlashInferImpl.__init__ ----------------------------------------
    src = sub(
        src,
        """        self.is_kvcache_nvfp4 = kv_cache_dtype.startswith("nvfp4")
        self.kv_cache_dtype = "nvfp4" if self.is_kvcache_nvfp4 else kv_cache_dtype""",
        """        self.is_kvcache_nvfp4 = kv_cache_dtype.startswith("nvfp4")
        # Consumer Blackwell serves NVFP4 KV via the FA2 paged reader / XQA
        # decode instead of trtllm-gen; see FlashInferMetadataBuilder.__init__.
        self.use_fa2_nvfp4_kv = (
            self.is_kvcache_nvfp4
            and current_platform.is_device_capability_family(120)
        )
        self.kv_cache_dtype = "nvfp4" if self.is_kvcache_nvfp4 else kv_cache_dtype""",
        1,
        "impl.__init__ flag",
    )

    # The pre-allocated FP8 output buffer is a trtllm-gen workaround only.
    src = sub(
        src,
        """        if self.is_kvcache_nvfp4 and vllm_config is not None:""",
        """        if (
            self.is_kvcache_nvfp4
            and not self.use_fa2_nvfp4_kv
            and vllm_config is not None
        ):""",
        1,
        "impl fp8 out buffer",
    )

    # ---- 7. forward(): fp8 output round-trip -------------------------------
    # Only the trtllm-gen kernel forces FP8 output. On the FA2/XQA path output
    # already arrives in the model dtype, so the dequantize round-trip must be
    # skipped -- and _nvfp4_fp8_out is None there anyway (site 6).
    src = sub(
        src,
        "needs_fp8_out = self.is_kvcache_nvfp4 and output.dtype != FP8_DTYPE",
        "needs_fp8_out = (\n                    self.is_kvcache_nvfp4\n                    and not self.use_fa2_nvfp4_kv\n                    and output.dtype != FP8_DTYPE\n                )",
        3,
        "needs_fp8_out",
    )

    src = sub(
        src,
        """                    needs_fp8_out_prefill = (
                        self.is_kvcache_nvfp4 and output.dtype != FP8_DTYPE
                    )""",
        """                    needs_fp8_out_prefill = (
                        self.is_kvcache_nvfp4
                        and not self.use_fa2_nvfp4_kv
                        and output.dtype != FP8_DTYPE
                    )""",
        1,
        "needs_fp8_out_prefill",
    )

    # ---- 8. Builder: FAIL LOUDLY on a non-head-major layout -------------
    # THE SAFETY NET. Site 2 expresses a *preference* via
    # supported_kv_cache_layouts(), but that hook runs in the worker where the
    # ambient VllmConfig is not populated, so it silently returns None and the
    # resolver picks its own default -- measured: it chose LBNHC (== the legacy
    # NHD, token-major) on 2026-09-18. NVFP4 under a token-major layout does not
    # error, it CORRUPTS: K and V head rows interleave within each token, so the
    # per-side [data | scale] offsets land inside the other side's data and the
    # model returns plausible-looking garbage. Refuse to run instead.
    # The launcher sets VLLM_KV_CACHE_LAYOUT=HND to satisfy this.
    src = sub(
        src,
        """        # Compute per-phase Q dtype.  On SM90 (XQA decode), the prefill and""",
        """        if self.is_kvcache_nvfp4:
            _layout = get_flashinfer_layout_string(self.kv_cache_layout)
            if _layout != "HND":
                raise ValueError(
                    "NVFP4 KV cache requires the head-major HND (LBHNC) KV "
                    f"cache layout; resolved layout is {_layout!r}. NVFP4 packs "
                    "each K/V side's [data | scale] regions inside that side's "
                    "byte range, which is only coherent when a side's heads own "
                    "one contiguous region per page. Under a token-major layout "
                    "the cache would be silently corrupted rather than error. "
                    "Set VLLM_KV_CACHE_LAYOUT=HND."
                )

        # Compute per-phase Q dtype.  On SM90 (XQA decode), the prefill and""",
        1,
        "builder layout assertion",
    )

    # ---- 9. Builder.get_q_data_type: model-dtype Q on the FA2 path ------
    # MEASURED FAILURE, 2026-09-18 18:20: without this the engine dies at
    # startup with
    #     AssertionError: fp8 tensor core is not supported in fa2 backend
    # Upstream matches Q dtype to the KV dtype and hands nvfp4 an FP8 query,
    # which is a trtllm-gen-only contract -- FA2 has no fp8 tensor-core path.
    # Note the block just above already does exactly this for `fp8` KV on
    # sm120 ("Architectures with only fa2 ... keep the model dtype for Q
    # there"); nvfp4 simply was not given the same treatment.
    src = sub(
        src,
        """        if cache_dtype.startswith("nvfp4"):
            return FlashInferBackend.get_dtype_for_flashinfer("fp8_e4m3")""",
        """        if cache_dtype.startswith("nvfp4"):
            if current_platform.is_device_capability_family(120):
                # The FA2 paged nvfp4 reader (consumer Blackwell) consumes
                # model-dtype queries; FP8-Q is a trtllm-gen-only contract.
                return self.model_config.dtype
            return FlashInferBackend.get_dtype_for_flashinfer("fp8_e4m3")""",
        1,
        "get_q_data_type nvfp4",
    )

    # ---- 10. Impl.forward: let NVFP4 reach the XQA decode path -----------
    # MEASURED FAILURE, 2026-09-18 18:21: "assert not self.is_kvcache_nvfp4" at
    # the top of the decode_with_xqa branch. Upstream's XQA decode never handled
    # nvfp4, so it asserted the combination away; the fork deletes the assert
    # ("Remove stale NVFP4 assertion in XQA forward path") and feeds XQA the
    # scale factors instead (site 11). The assert is LOAD-BEARING until site 11
    # lands -- without the scales XQA would read packed fp4 bytes as a normal
    # dtype and silently return garbage -- so keep it for every path except the
    # sm120 one we are wiring up.
    src = sub(
        src,
        """        if decode_with_xqa:
            assert not use_dcp
            assert not self.is_kvcache_nvfp4""",
        """        if decode_with_xqa:
            assert not use_dcp
            if not self.use_fa2_nvfp4_kv:
                # Still a real invariant off the sm120 path: only the sm120
                # XQA call below passes kv_cache_sf.
                assert not self.is_kvcache_nvfp4""",
        1,
        "xqa nvfp4 assertion",
    )

    # ---- 11. Impl.forward: pass the NVFP4 scale factors to XQA -----------
    # Mirrors the fork exactly, and note the calling convention DIFFERS per
    # kernel: XQA takes the full per-side [data | scale] view as `kv_cache`
    # plus the scales separately in `kv_cache_sf`, whereas trtllm-gen takes the
    # data-only view (`nvfp4_kv_data`). FlashInfer 0.6.18's
    # xqa_batch_decode_with_kv_cache already accepts kv_cache_sf, so no kernel
    # work is needed. Getting this wrong is silent corruption, not an error.
    src = sub(
        src,
        """                        mask=attn_metadata.decode.mask,
                        q_cu_seq_lens=attn_metadata.decode.q_cu_seq_lens,
                    )""",
        """                        mask=attn_metadata.decode.mask,
                        q_cu_seq_lens=attn_metadata.decode.q_cu_seq_lens,
                        kv_cache_sf=(
                            nvfp4_kv_block_scales if self.is_kvcache_nvfp4 else None
                        ),
                    )""",
        1,
        "xqa kv_cache_sf",
    )

    # Stamp the version marker so re-runs are detected.
    src = sub(
        src,
        "logger = init_logger(__name__)",
        "logger = init_logger(__name__)\n\n# sm120-nvfp4-kv-patch v4 (see ~/qwen-vllm/patch-nightly-sm120-nvfp4-kv.py)",
        1,
        "version marker",
    )

    TARGET.write_text(src)
    print(f"Patched {TARGET}")
    print("Sites applied: 14. Restore with:")
    print(f"  cp {TARGET.with_suffix('.py.orig')} {TARGET}")


if __name__ == "__main__":
    main()
