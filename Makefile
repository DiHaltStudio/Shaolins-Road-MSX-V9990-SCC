# Shao-lin's Road on MSX1 + V9990 (GFX9000): an unofficial homage port by DiHalt Studio.
#
#   make run          play the ROM in openMSX (Sony HB-10P + GFX9000)
#   make run-turbor   the same on a turbo R (Panasonic FS-A1GT + GFX9000)
#   make manual       build docs/manual/manual-en.pdf and manual-es.pdf (needs pdflatex)
#   make port         build the ROM from source (needs the arcade data, see README)
#   make test         automatic soak test of the built ROM (openMSX on an X display)
#   make timing       interrupts, game ticks and presentation time in the attract demo
#   make release      build the ROM and copy it to release/ (the file to attach to a release)
#
# `run` plays release/shaolins_v9990.rom when it is there, else the one `make port` built.
ARCADE         ?= arcade
PY             ?= python3
OPENMSX        ?= openmsx
MACHINE        ?= Sony_HB-10P
MACHINE_TURBOR ?= Panasonic_FS-A1GT
TEST_DISPLAY   ?= :99
TEST_SECS      ?= 600
BUILT_ROM       = build/port/shaolins_v9990.rom
PORT_SYM        = build/port/shaolins_v9990.sym
ROM            ?= $(firstword $(wildcard release/shaolins_v9990.rom $(BUILT_ROM)))
RUN_ARGS        = -ext gfx9000 -cart $(ROM) -romtype KonamiSCC \
                  -command "after time 1 {set videosource GFX9000}"

export ARCADE OPENMSX MACHINE TEST_DISPLAY

all: run

# play the port on an MSX1 (Sony HB-10P) / a turbo R, both with a GFX9000
run:
	@test -n "$(ROM)" || { echo "no ROM: put shaolins_v9990.rom in release/ or run 'make port'"; exit 1; }
	$(OPENMSX) -machine $(MACHINE) $(RUN_ARGS)

run-turbor:
	@test -n "$(ROM)" || { echo "no ROM: put shaolins_v9990.rom in release/ or run 'make port'"; exit 1; }
	$(OPENMSX) -machine $(MACHINE_TURBOR) $(RUN_ARGS)

# build/port/shaolins_v9990.rom (1 MiB, Konami SCC mapper)
port:
	@test -f $(ARCADE)/build/maincpu_6000.bin || { echo "arcade data not found in $(ARCADE)/ (see README, 'Building from source')"; exit 1; }
	$(PY) tools/build_port.py

release: port
	mkdir -p release
	cp $(BUILT_ROM) release/shaolins_v9990.rom

# automatic test: three soak runs of $(TEST_SECS) emulated seconds (openMSX on
# the X display $(TEST_DISPLAY), e.g. Xvfb :99), PASS or FAIL
test: port
	sh tools/openmsx/test.sh $(BUILT_ROM) $(PORT_SYM) build/test $(TEST_SECS)

timing: port
	TM_LEN=8 sh tools/openmsx/timing.sh $(BUILT_ROM) $(PORT_SYM)

# user manual (LaTeX -> PDF, English and Spanish)
MANUAL_LANGS ?= en es
manual:
	$(PY) tools/manual_images.py docs/manual .
	cd docs/manual && for l in $(MANUAL_LANGS); do for i in 1 2; do \
	  pdflatex -interaction=nonstopmode -jobname=manual-$$l "\def\manlang{$$l}\input{manual}" >build-$$l.log 2>&1 || { echo "manual-$$l failed: see docs/manual/build-$$l.log"; exit 1; }; \
	done; done
	@echo 'Manuals: docs/manual/manual-*.pdf'

clean:
	rm -rf build

.PHONY: all run run-turbor port release test timing manual clean
