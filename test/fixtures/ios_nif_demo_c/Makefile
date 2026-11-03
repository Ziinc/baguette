# A typical elixir_make Makefile: one shared library in $(MIX_APP_PATH)/priv.
PRIV = $(MIX_APP_PATH)/priv
CFLAGS += -O2 -fPIC -I$(ERTS_INCLUDE_DIR)
ifeq ($(shell uname -s),Darwin)
LDFLAGS += -dynamiclib -undefined dynamic_lookup
else
LDFLAGS += -shared
endif

all: $(PRIV)/ios_nif_demo_c.so

$(PRIV)/ios_nif_demo_c.so: c_src/ios_nif_demo_c.c
	mkdir -p $(PRIV)
	$(CC) $(CFLAGS) $< $(LDFLAGS) -o $@
