# Audio implementation provenance

The preceding v7.8.5 FFT and spectrum envelope were adapted from
https://github.com/out-of-mana8/fpga-audio-spectrum-analyzer
Reviewed upstream commit: c8f813a88d1c0b09f77b9c893eada96ff0760ef2.
The upstream README describes MIT licensing; retain and verify the upstream
copyright/permission notice before redistribution. No license is invented here.
The reviewed README, two reference source files and fetch metadata are preserved
unchanged in upstream_reference/. These files are not synthesis inputs.

v7.9 replaces the FFT computation with a radix-2 DIF implementation:
natural-order loading, descending spans, split before rotation, bit-reversed
bin reads, mathematically generated quarter-wave Q15 coefficients, and an
iterative integer square root of the sum of squares for magnitude.
The PCM capture interface and the historical display log/envelope/peak logic
retain prior design influence. Geometry, overlay and controls are preserved.
This is a substantive refactor, not an independently audited clean-room design
and not proof of competition originality compliance. AI assisted this rewrite.
Numerical results are not bit-identical to the previous approximation.
