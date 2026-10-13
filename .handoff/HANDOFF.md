# HANDOFF

Updated: 2026-10-13
Previous agent: Claude (claude-opus) via DeepSeek Harness
Session closed due to: in progress (checkpoint; user asked for handoff + speed)

## Objective received
Fork consi/axial -> full SpaceExplorer configurator: 6x6 remap in real pipeline, live 3D viz,
tuning (curves/deadzone/smoothing/calibration/locks), 15-button mapping (shortcuts/macros/
commands/launch), per-app profiles (auto-switch, duplicate/import/export), live editing, universal build.

## Work completed
- Fork: github.com/Alenov23/axial, branch `spacecontrol` (remote origin=fork, upstream=consi).
- include/axial/mapping.hpp: Processor (calibrate->deadzone->curve->sensitivity->smoothing->matrix->enable/T,R->lock->gain/invert).
- core.hpp: Flags::mapped/processed; EventQueue lookback coalescing + protectFront.
- src/service.mm: Profile uses Mapping; parseProfile (new JSON fields); macros/open/shell; new
  driver actions (group,pause,resetSpeed); passthrough=false withholds native button;
  `preview` control op; status has activeProfile/previewProfile; mapped monitor stream.
- app/bridge.cpp: AxialPreviewReadMapped, AxialShapeInput.
- tests/mapping_tests.cpp (+Tests.cmake): PASS, 0 allocations, ~34 ns/report.
- Swift: ProfileModel.swift, LiveView.swift, MappingView.swift, TuningView.swift, ButtonsView.swift;
  Axial.swift: old Profile/SettingsView removed, profile ops (preset/duplicate/import/export), syncPreview.

## Decisions
- Build dir MUST be space-free: ~/Library/Caches/axial-build/native (OpenSSL breaks on "31. 6DoF").
- Event ABI and frameworks untouched -> installed /Library/Frameworks keep working.
- Legacy fields keep meaning: gain/invert = output stage, deadzone = input stage.

## Resume at
- Write app/ProfilesView.swift + app/SettingsView.swift (tabs Live/Mapping/Tuning/Buttons/Profiles/Test/Service),
  add new swift files to axial_app_sources in CMakeLists.txt, fix compile errors.
- Next command: cmake --build ~/Library/Caches/axial-build/native

## Git status
- Commit WIP often: `git add -A && git commit -m "wip: spacecontrol"`
