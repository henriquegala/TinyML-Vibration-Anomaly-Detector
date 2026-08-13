# TinyML Vibration Anomaly Detector — HDL Accelerator

> ⚠️ **Draft / Private repo — Work in Progress.** Developed during a summer research internship at the Instituto de Telecomunicações (IT), as the Week 4 deliverable of a 4-week accelerator-design plan. Publication pending advisor confirmation.

## Overview
A synchronous, parametrized hardware accelerator for **anomaly detection on industrial vibration sensors**, using an **autoencoder** architecture. Builds directly on the parametrized hidden-layer base from [`ANN-Hidden-Layer-HDL`](../ANN-Hidden-Layer-HDL) — same Q8.8 fixed-point philosophy, extended with a wider accumulator and a unified activation/mapping block.

This project was chosen after evaluating three TinyML application candidates (voice keyword spotting, IMU-based gesture recognition, vibration-based anomaly detection) for best fit with the quantization/parametrization work already done, and lowest risk of not finishing within the 4-week window.

## Architecture
```
Inputs X [N x 16b] ──┐
                      ├──► mac_tree ──► z_out (39b, Q8.8) ──► activation_unit ──► Y [16b, Q8.8]
Weights W [N x 16b] ─┘
              (connected inside top-level module: tinyml_top)
```
- **Datapath:** synchronous, parametrized (input count, bit widths configurable via `parameters`/`generics`).
- **`mac_tree`** (file `mac_tree.sv`): computes `Z = Σ(W_i · X_i) + Bias` in Q8.8, pipelined, 3–4 pipeline register stages.
- **Accumulator:** wide, **39-bit** `z_out` produced by `mac_tree`, before truncation back down to Q8.8 — this is the direct fix for the saturation/wraparound issue left as "future work" in the previous project, where each product was truncated individually with no protection.
- **`activation_unit`** (file `activation_unit.sv`): applies `Y = f(Z)`, non-linearity selectable via parameter between:
  - ReLU
  - LeakyReLU
  - Hard-Swish
  - Sigmoid (ROM/LUT or PWL)
  Also handles clamping/saturation and ROM address mapping where applicable.
- **`tinyml_top`** (file `tinyml_top.sv`): top-level module, connects `mac_tree` and `activation_unit`.
- **Design philosophy:** clean, synthesizable code, no latches, fully synchronous testbench. File names match module names exactly (industry convention — required for correct EDA tool dependency indexing in Vivado).

## Optional: Python Test-Data Generator
A small (~15-line) Python script can generate `dados_sensor.txt` — normal and anomalous vibration waveforms pre-converted to Q8.8 hex, for feeding the testbench without hand-writing test vectors. Lives in `tools/` if used; not required to build or simulate the design.

## Open Questions / TODO
- [ ] **Derive the 39-bit accumulator width formally.** Working hypothesis: Q8.8 × Q8.8 product = 32 bits, plus `log2(N)` margin for summing N inputs. 39 bits suggests either a larger N than the original 4-input layer, or extra safety margin — not yet confirmed against the actual N used in this design. Needs to be derived and documented before this repo is considered complete.

## Repository Structure
```
systemverilog/
├── src/
│   ├── mac_tree.sv          module mac_tree — MAC tree + 39-bit accumulator
│   ├── activation_unit.sv    module activation_unit — ReLU/LeakyReLU/Hard-Swish/Sigmoid
│   └── tinyml_top.sv         module tinyml_top — top-level, connects the two above
└── tb/
    └── tb_tinyml_top.sv       module tb_tinyml_top — synchronous testbench
vhdl/                          VHDL equivalent (if/when ported)
docs/                          Design notes, derivation of accumulator width once resolved
reports/                       Synthesis/simulation results once available
tools/                         Simulation/synthesis scripts, optional Python test-data generator
```

## Status
Week 4 of 4 — active build. Prior weeks (quantization research, HDL parametrization, cycle-vs-resource tradeoffs, application selection) are complete; this repo tracks the accelerator implementation itself. See Issues for the week-by-week breakdown.
