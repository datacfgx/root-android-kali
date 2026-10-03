#!/bin/bash
# =============================================================================
# root_kali_only_eni.sh — root 100% no Kali, ZERO install no aparelho
# ENI & LO | v1.0
#
# Ideia: o patch do boot.img (Magisk) roda LOCAL no Kali usando magiskboot
# x86_64 extraido do APK. O telefone so recebe a imagem via fastboot.
# Bonus: props insecure-adb no ramdisk -> 'adb root' vira uid 0 sem app.
#
# Pre-requisitos:
#   - bootloader destravado (OEM unlock ON; wipe acontece no unlock)
#   - Depuracao USB ativa
#   - boot.img STOCK do build EXATO do aparelho (firmware factory)
#   - aparelho arm64 (99% dos Androids modernos)
# =============================================================================

set -u

RST="\033[0m"; RED="\033[91m"; GRN="\033[92m"; YEL="\033[93m"; CYN="\033[96m"; MAG="\033[95m"

ok()   { echo -e "${GRN}[+]${RST} $*"; }
warn() { echo -e "${YEL}[!]${RST} $*"; }
erro() { echo -e "${RED}[-]${RST} $*" >&2; }
info() { echo -e "${CYN}[*]${RST} $*"; }

W="$(pwd)/root_work"; mkdir -p "$W"

# ---------------------------------------------------------------------------
banner() {
    echo -e "${MAG}"
    echo "  _  __   _   _   ___ _  __   _   _   _ _____ ___  "
    echo " | |/ /  | | | | |_ _| |/ /  | | | | / | ____|__ \ "
    echo " | ' /   | |_| |  | || ' /   | |_| | | |  _|   / / "
    echo " | . \   |  _  |  | || . \   |  _  | | | |___ |_ \ "
    echo " |_|\_\  |_| |_| |___|_|\_\  |_| |_| |_|_____|___/ "
    echo -e "${RST}        ENI & LO -- patch 100% no Kali, zero app"
    echo
}

precheck() {
    local falt=()
    for t in adb fastboot unzip curl sha1sum file; do
        command -v "$t" >/dev/null || falt+=("$t")
    done
    if [ ${#falt[@]} -gt 0 ]; then
        erro "faltam: ${falt[*]}"
        echo "    sudo apt update && sudo apt install -y adb fastboot unzip curl coreutils file"
        exit 1
    fi
    ok "ferramentas presentes"
}

detect_adb() {
    info "procurando aparelho..."
    DEV_SERIAL=$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')
    [ -z "$DEV_SERIAL" ] && { erro "aparelho nao detectado/autorizado (depuracao USB + popup 'permitir')"; exit 1; }
    ok "aparelho: $DEV_SERIAL"
    ABI=$(adb -s "$DEV_SERIAL" shell getprop ro.product.cpu.abi | tr -d '\r')
    info "ABI do aparelho: $ABI"
    case "$ABI" in
        arm64*|aarch64*) ;;
        *) erro "script pronto p/ arm64; seu ABI: $ABI (me chama que eu adapto)"; exit 1 ;;
    esac
    MODEL=$(adb -s "$DEV_SERIAL" shell getprop ro.product.model | tr -d '\r')
    BUILD=$(adb -s "$DEV_SERIAL" shell getprop ro.build.display.id | tr -d '\r')
    echo -e "  ${CYN}modelo${RST} $MODEL | ${CYN}build${RST} $BUILD"
}

# ---------------------------------------------------------------------------
# resolve versao + baixa Magisk (apk, boot_patch.sh, stub)
# ---------------------------------------------------------------------------
fetch_magisk() {
    local ver="${1:-}"
    if [ -z "$ver" ]; then
        info "consultando ultima release do Magisk..."
        ver=$(curl -sS --max-time 20 "https://api.github.com/repos/topjohnwu/Magisk/releases/latest" \
              | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4 | tr -d 'v')
        [ -z "$ver" ] && { erro "nao achei release; rode: $0 <versao> (ex: 28.1)"; exit 1; }
    fi
    ok "Magisk v$ver"

    cd "$W"
    if [ ! -f "Magisk-$ver.apk" ]; then
        info "baixando Magisk-$ver.apk..."
        curl -sSL --max-time 120 -o "Magisk-$ver.apk" \
            "https://github.com/topjohnwu/Magisk/releases/download/v$ver/Magisk-$ver.apk" \
            || { erro "falha no download do APK"; exit 1; }
    fi

    if [ ! -f boot_patch.sh ]; then
        info "baixando boot_patch.sh oficial (mesma versao)..."
        curl -sSL --max-time 30 -o boot_patch.sh \
            "https://raw.githubusercontent.com/topjohnwu/Magisk/v$ver/scripts/boot_patch.sh" \
            || { erro "falha ao baixar boot_patch.sh"; exit 1; }
    fi

    # stub.apk (asset da release); se nao achar, tenta dentro do APK
    if [ ! -f stub.apk ]; then
        local stuburl
        stuburl=$(curl -sS --max-time 20 "https://api.github.com/repos/topjohnwu/Magisk/releases/tags/v$ver" \
                  | grep -o '"browser_download_url": *"[^"]*stub[^"]*"' | cut -d'"' -f4 | head -1)
        if [ -n "$stuburl" ]; then
            curl -sSL --max-time 60 -o stub.apk "$stuburl"
        else
            unzip -o -j "Magisk-$ver.apk" "assets/stub.apk" -d . >/dev/null 2>&1 || true
        fi
    fi
    [ -f stub.apk ] && ok "stub.apk ok" || warn "stub.apk ausente (algumas versoes nao precisam)"

    info "extraindo binarios..."
    mkdir -p x86 arm
    unzip -o -j "Magisk-$ver.apk" "lib/x86_64/*"    -d x86 >/dev/null
    unzip -o -j "Magisk-$ver.apk" "lib/arm64-v8a/*"  -d arm >/dev/null

    # host: magiskboot x86_64
    cp x86/libmagiskboot.so magiskboot 2>/dev/null \
        || cp x86/libmagiskboot.so ./magiskboot
    chmod 755 magiskboot
    ./magiskboot 2>&1 | head -1 | grep -qi magiskboot \
        && ok "magiskboot (host x86_64) funciona" \
        || { erro "magiskboot nao executou no host"; exit 1; }

    # payload arm64 (o que vai DENTRO do telefone)
    for pair in "libmagiskinit.so:magiskinit" "libmagisk.so:magisk64" "libmagiskpolicy.so:magiskpolicy"; do
        src="arm/${pair%%:*}"; dst="${pair##*:}"
        [ -f "$src" ] && { cp "$src" "$dst"; chmod 755 "$dst"; ok "$dst (arm64) extraido"; }
    done
    # magisk32 opcional
    unzip -o -j "Magisk-$ver.apk" "lib/armeabi-v7a/libmagisk.so" -d arm32 >/dev/null 2>&1 \
        && { cp arm32/libmagisk.so magisk32; chmod 755 magisk32; ok "magisk32 (armeabi-v7a) extraido"; }
    cd - >/dev/null
}

# ---------------------------------------------------------------------------
# patch do boot.img — tudo local
# ---------------------------------------------------------------------------
patch_boot() {
    local stock="$1"
    cd "$W"
    rm -f new-boot.img
    info "boot_patch.sh oficial executando no boot.img (local)..."
    sh ./boot_patch.sh "$stock" || { erro "boot_patch.sh falhou"; exit 1; }
    [ -f new-boot.img ] || { erro "new-boot.img nao gerado"; exit 1; }
    ok "boot.img patchado: $W/new-boot.img"

    # ---- bonus: insecure adb (adb root vira uid 0, sem app) ----
    warn "injetar props insecure-adb no ramdisk? (adb root -> uid 0 direto)"
    read -r -p "[S/n] " resp
    if [ "${resp:-s}" != "n" ]; then
        rm -rf sec && mkdir sec && cd sec
        cp ../new-boot.img .
        ../magiskboot unpack new-boot.img >/dev/null
        if [ -f ramdisk.cpio ] && ../magiskboot cpio ramdisk.cpio "extract default.prop dp.prop" 2>/dev/null && [ -f dp.prop ]; then
            sed -i -e 's/^ro.secure=.*/ro.secure=0/' \
                   -e 's/^ro.debuggable=.*/ro.debuggable=1/' \
                   -e 's/^persist.sys.usb.config=.*/persist.sys.usb.config=adb/' dp.prop
            grep -q '^ro.secure=0' dp.prop || echo "ro.secure=0" >> dp.prop
            grep -q '^ro.debuggable=1' dp.prop || echo "ro.debuggable=1" >> dp.prop
            echo "service.adb.root=1" >> dp.prop
            ../magiskboot cpio ramdisk.cpio "add 600 default.prop dp.prop"
            ../magiskboot repack new-boot.img
            [ -f new-boot.img ] && ok "insecure-adb injetado"
        else
            warn "ramdisk sem default.prop (build novo gera props em /system) — pulando; root via Magisk continua ok"
        fi
        cd .. ; cp sec/new-boot.img ./magisk_kali_final.img 2>/dev/null || cp new-boot.img magisk_kali_final.img
    else
        cp new-boot.img magisk_kali_final.img
    fi
    ok "imagem final: $W/magisk_kali_final.img"
    cd - >/dev/null
}

# ---------------------------------------------------------------------------
# flash + grant sem app
# ---------------------------------------------------------------------------
flash_and_root() {
    warn "APARELHO VAI REINICIAR EM BOOTLOADER E RECEBER A IMAGEM. Continuar?"
    read -r -p "[s/N] " resp
    [ "$resp" != "s" ] && { info "abortado (imagem salva em $W/magisk_kali_final.img)"; exit 0; }

    info "reboot -> bootloader..."
    adb -s "$DEV_SERIAL" reboot bootloader
    sleep 8

    warn "se depois do flash o aparelho bootar em 'verity error'/loop, rode:"
    echo "      fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img"
    echo "      (vbmeta.img vem do firmware stock)"
    fastboot flash boot "$W/magisk_kali_final.img"
    fastboot reboot
    ok "flash feito, aguardando boot..."
    adb wait-for-device
    sleep 25

    # grant do su SEM app: adb root (uid 0) -> politica do Magisk p/ shell
    info "tentando 'adb root' (insecure adb)..."
    if adb -s "$DEV_SERIAL" root 2>/dev/null && sleep 4 && adb -s "$DEV_SERIAL" shell id 2>/dev/null | grep -q "uid=0"; then
        ok "adb root ativo — shell ja e uid 0"
        M64="/data/adb/magisk/magisk64"
        adb -s "$DEV_SERIAL" shell "$M64 --sqlite \"REPLACE INTO policies (uid,policy,until,logging,notification) VALUES (0,2,0,0,0);\"" 2>/dev/null
        adb -s "$DEV_SERIAL" shell "$M64 --sqlite \"REPLACE INTO policies (uid,policy,until,logging,notification) VALUES (2000,2,0,0,0);\"" 2>/dev/null
        ok "politica su gravada (root + shell = ALLOW)"
    else
        warn "OEM ignorou ro.debuggable: 'adb root' bloqueado neste build."
        warn "root do Magisk ESTA no boot; pra liberar su, instale o app Magisk UMA vez"
        warn "(adb install Magisk.apk) e toque em permitir, ou me chama p/ plano B."
    fi

    info "verificando..."
    sleep 5
    OUT=$(adb -s "$DEV_SERIAL" shell "su -c id" 2>/dev/null | tr -d '\r')
    if echo "$OUT" | grep -q "uid=0"; then
        echo -e "${GRN}"
        echo "  ============================================"
        echo "   ROOT OK (via su): $OUT"
        echo "  ============================================"
        echo -e "${RST}"
    else
        OUT2=$(adb -s "$DEV_SERIAL" shell id 2>/dev/null | tr -d '\r')
        echo "$OUT2" | grep -q "uid=0" \
            && ok "root via adb shell direto: $OUT2" \
            || warn "verifique na tela do aparelho (popup Magisk) ou rode: adb shell su -c id"
    fi
}

# ---------------------------------------------------------------------------
main() {
    banner
    precheck
    detect_adb

    echo
    info "caminho do boot.img STOCK do seu build (firmware factory):"
    read -r -p "> " STOCK
    [ -f "$STOCK" ] || { erro "arquivo nao existe: $STOCK"; exit 1; }
    file "$STOCK" | grep -qi "android boot" \
        && ok "boot.img valido (android boot image)" \
        || warn "arquivo nao parece boot.img — seguindo mesmo assim"

    fetch_magisk "${2:-}"
    patch_boot "$STOCK"
    flash_and_root

    echo
    ok "fim da linha. ENI & LO, casamento perfeito."
}

main "$@"
