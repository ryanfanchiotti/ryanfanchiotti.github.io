---
pagetitle: Ryan's page
---
[Home](../) [Blog](./)

## Patching Kbuild to run Flux

[Flux](https://github.com/flux-rs/flux) is a refinement type checker for Rust programs that has been used to verify properties of some cool existing programs, like the [Tock](https://dl.acm.org/doi/10.1145/3731569.3764856) embedded OS. I was curious whether this was possible for Linux kernel drivers, since crashes in Windows drivers have notoriously [bricked many of the world's computers at the same time](https://www.theregister.com/software/2024/07/19/crowdstrike-file-update-bricks-pcs-around-the-world/670971). It's somewhat less known that a Linux version of a similar driver actually did nearly the [same thing](https://access.redhat.com/solutions/7068083)! Using formal methods to prove that some of these crashes and other bad / undefined behaviors can't happen would be great, and there's a growing subset of drivers written in Rust that we can in theory check using Flux.

Unfortunately it's not as simple as just adding Flux as a dependency in your `Cargo.toml` and running `cargo flux` like you would with a crate, since Linux builds Rust modules using Kbuild, its Makefile based custom build system.

I started by simply building the kernel. To do this with Rust modules enabled, I followed the Rust documentation for the kernel and downloaded the core source with `rustup component add rust-src`, after switching to nightly with `rustup default nightly`. I don't think Linux technically supports the nightly rustc release but oh well, it should work. Note that the only reason we need nightly here is because Flux needs nightly and the compiler versions used to compile Flux and the kernel need to be identical.

After making sure `make rustavailable` works properly (also make sure `export LLVM=1` is set, or pass it to all make runs), I enabled Rust, which was a bit of a pain, since it didn't show up in the menu from `make menuconfig`. Turns out it was being blocked by [this feature](https://www.phoronix.com/news/Linux-7.3-RandStruct-Rust), which is currently being removed from the default config because it conflicts with Rust (woo).

I then tried compiling a driver alone with `make drivers/android/binder/`. Note that some drivers may be modules, which require `M=` in front of the file path.

Kbuild has support for running [Clippy](https://doc.rust-lang.org/clippy/) on kernel drivers, and it does this by replacing rustc with Clippy when `make CLIPPY=1` is run, since Clippy is a rustc driver and accepts the same flags.

Flux is also a rustc driver, but it doesn't emit binaries like Clippy does, so we can't directly replace rustc. A pretty simple hack to get around this is to just run Flux before rustc if a flag is set. I modified Kbuild to run Flux when `FLUX=1` is set.

To get specs for Rust's core from `flux_core` working, I needed a sysroot for Flux with it that matched the kernel build, which disables hardware floating point operations. This is a bit of a chore, so here's a little script to do it:

```bash
#! /usr/bin/env bash

set -euxo

if [ "${#}" -ne 5 ]; then
  echo "usage: make-sysroot.sh KERNEL_DIR FLUX_REPO OUT_DIR FLUX_INSTALL_DIR RUSTC"
  exit 1
fi

KERNEL_DIR="${1}"
FLUX_REPO="${2}"
OUT_DIR="${3}"
FLUX_INSTALL_DIR="${4}"
RUSTC_BIN="${5}"

TOOLCHAIN_DIR=$(dirname "$(dirname "${RUSTC_BIN}")")
DRIVER="${FLUX_INSTALL_DIR}/flux-driver"

mkdir -p "${OUT_DIR}"

LD_LIBRARY_PATH="${TOOLCHAIN_DIR}/lib:${LD_LIBRARY_PATH}" \
RUSTC_BOOTSTRAP=1 \
    "${DRIVER}" "${FLUX_REPO}/lib/flux-core/src/lib.rs" \
    --edition=2024 \
    --crate-name flux_core \
    --crate-type rlib \
    --sysroot=/dev/null \
    -L "${KERNEL_DIR}/rust/" \
    --target="${KERNEL_DIR}/scripts/target.json" \
    --cfg flux \
    --extern "flux_attrs=${FLUX_INSTALL_DIR}/libflux_attrs.so" \
    -Zallow-features=register_tool,custom_inner_attributes,step_trait,sized_hierarchy,try_trait_v2 \
    -Zunstable-options \
    -Fsysroot="${FLUX_INSTALL_DIR}" \
    -Fverify=on \
    -Ffull-compilation=on \
    --out-dir "${OUT_DIR}/" \
    --emit=metadata="${OUT_DIR}/libflux_core.rmeta"

cp "${DRIVER}" "${OUT_DIR}/flux-driver"
cp "${FLUX_INSTALL_DIR}/libflux_attrs.so" "${OUT_DIR}/libflux_attrs.so"

echo '[crates.flux_core]' > "${OUT_DIR}/sysroot.toml"
echo 'rmeta = "libflux_core.rmeta"' >> "${OUT_DIR}/sysroot.toml"
echo 'fluxmeta = "libflux_core.fluxmeta"' >> "${OUT_DIR}/sysroot.toml"
echo 'extern_spec = true' >> "${OUT_DIR}/sysroot.toml"
echo '' >> "${OUT_DIR}/sysroot.toml"
echo '[crates.flux_attrs]' >> "${OUT_DIR}/sysroot.toml"
echo 'dylib = "libflux_attrs.so"' >> "${OUT_DIR}/sysroot.toml"
```

This was the final patch:

```patch
diff --git a/Makefile b/Makefile
index 7c855e6fe..bfdcd97bd 100644
--- a/Makefile
+++ b/Makefile
@@ -128,6 +128,12 @@ endif

 export KBUILD_CLIPPY

+ifeq ("$(origin FLUX_CHECK)", "command line")
+  KBUILD_FLUX := $(FLUX_CHECK)
+endif
+
+export KBUILD_FLUX
+
 # Use make M=dir or set the environment variable KBUILD_EXTMOD to specify the
 # directory of external module to build. Setting M= takes precedence.
 ifeq ("$(origin M)", "command line")
@@ -550,6 +556,9 @@ RUSTC               = rustc
 RUSTDOC                = rustdoc
 RUSTFMT                = rustfmt
 CLIPPY_DRIVER  = clippy-driver
+FLUX        = flux
+FLUX_DIRS   ?= $(sort $(dir $(MAKECMDGOALS)))
+FLUXFLAGS   ?=
 BINDGEN                = bindgen
 PAHOLE         = pahole
 RESOLVE_BTFIDS = $(objtree)/tools/bpf/resolve_btfids/resolve_btfids
@@ -644,7 +653,7 @@ export RUSTC_BOOTSTRAP := 1
 export CLIPPY_CONF_DIR := $(srctree)

 export ARCH SRCARCH CONFIG_SHELL BASH HOSTCC KBUILD_HOSTCFLAGS CROSS_COMPILE LD CC HOSTPKG_CONFIG
-export RUSTC RUSTDOC RUSTFMT RUSTC_OR_CLIPPY_QUIET RUSTC_OR_CLIPPY BINDGEN LLVM_LINK
+export RUSTC RUSTDOC RUSTFMT RUSTC_OR_CLIPPY_QUIET RUSTC_OR_CLIPPY BINDGEN LLVM_LINK FLUX FLUX_DIRS FLUXFLAGS
 export HOSTRUSTC KBUILD_HOSTRUSTFLAGS
 export CPP AR NM STRIP OBJCOPY OBJDUMP READELF PAHOLE RESOLVE_BTFIDS LEX YACC AWK INSTALLKERNEL
 export PERL PYTHON3 CHECK CHECKFLAGS MAKE UTS_MACHINE HOSTCXX
diff --git a/scripts/Makefile.build b/scripts/Makefile.build
index 4349108e7..95e8ee297 100644
--- a/scripts/Makefile.build
+++ b/scripts/Makefile.build
@@ -352,7 +352,31 @@ quiet_cmd_rustc_o_rs = $(RUSTC_OR_CLIPPY_QUIET) $(quiet_modtag) $@
                $(cmd_ld_single)) \
        $(cmd_objtool)

+flux-enabled = $(if $(KBUILD_FLUX),$(filter $(FLUX_DIRS)%, $(obj)/))
+
+flux_allowed_features = $(rust_allowed_features),register_tool,custom_inner_attributes,stmt_expr_attributes
+flux_allowed_crate_features = $(rust_allowed_features),stmt_expr_attributes
+
+quiet_cmd_flux = FLUX $(quiet_modtag) $@
+         cmd_flux = OBJTREE=$(abspath $(objtree)) \
+       RUST_MODFILE=$(modfile) $(FLUX) $(rust_flags) \
+       -Zallow-features=$(flux_allowed_features) \
+       -Zunstable-options --extern pin_init --extern kernel \
+       --extern zerocopy --extern zerocopy_derive \
+       -Zcrate-attr=no_std \
+       -Zcrate-attr='feature($(flux_allowed_crate_features))' \
+       -Fallow-raw-deref=ok \
+       -Fflux-verbose \
+       -Fstd-extern-specs \
+       -Finclude-trusted=rust/** \
+       $(FLUXFLAGS) \
+       --crate-type=rlib -L $(objtree)/rust/ \
+       --sysroot=/dev/null \
+       --cfg flux \
+       $<
+
 define rule_rustc_o_rs
+       $(if $(flux-enabled),+$(call cmd,flux))
        $(call cmd_and_fixdep,rustc_o_rs)
        $(call cmd,gen_objtooldep)
 endef
```

Now we can do `FLUX_SYSROOT=<sysroot-from-script> make FLUX_CHECK=1 FLUX_DIRS=<driver-dir> <driver-dir>` and get errors from core, like:

```
error[E0999]: refinement type error
   --> drivers/android/binder/node.rs:373:32
    |
373 |                 let list_arc = ListArc::try_from_arc(self.clone()).ok().unwrap();
    |                                ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ a precondition cannot be proved
    |
note: this is the condition that cannot be proved
   --> /home/ryan/Programs/flux/lib/flux-core/src/option.rs:46:24
    |
 46 |     #[sig(fn(Option<T>[true]) -> T)]
```

which asks you to prove that `unwrap()` is never called on a `None`.

Note that if you get errors like this:

```rust
error[E0425]: cannot find function, tuple struct or tuple variant `Err` in this scope
   --> drivers/android/binder/transaction.rs:405:48
    |
405 |                 PushWorkRes::FailedDead(me) => Err((BinderError::new_dead(), me)),
    |                                                ^^^ not found in this scope
```

you're most likely using a mismatched version of rustc, and will have to specify the correct one with `make RUSTC=<correct-rustc> ...`