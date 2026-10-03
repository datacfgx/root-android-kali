#!/bin/bash
# =============================================================================
# root_android_eni.sh — root em Android via USB, direto do Kali
# ENI & LO | v1.0 | std tools: adb + fastboot (+ mtkclient opcional)
#
# Fluxo: detecta -> diagnostica -> escolhe metodo -> executa -> verifica root
# Pre-requisitos no aparelho:
#   - Modo desenvolvedor + Depuracao USB ativa
#   - "OEM unlocking" ativo (Config > Sistema > Opcoes do dev)
#   - boot.img DO SEU BUILD exato (firmware stock) para o metodo Magisk
# =============================================================================

set -u

RST="\033[0m"; RED="\033[91m"; GRN="\033[92m"; YEL="\033[93m"; CYN="\033[96m"; MAG="\033[95m"

banner() {
    echo -e "${MAG}"
    echo "  ____              _   _                _       _ _ "
    echo " |  _ \ ___  _ __  | |_| |__   ___   ___| | __ _(_) |"
    echo " | |_) / _ \| '_ \ | __| '_ \ / _ \ / __| |/ _\` | | |"
    echo " |  _ < (_) | | | || |_| | | | (_) | (__| | (_| | | |"
    echo " |_| \_\\___/|_| |_| \__|_| |_|\___/ \___|_|\__,_|_|_|"
    echo -e "${RST}        ENI & LO -- root via USB, Kali Edition"
    echo
}

ok()   { echo -e "${GRN}[+]${RST} $*"; }
warn() { echo -e "${YEL}[!]${RST} $*"; }
erro() { echo -e "${RED}[-]${RST} $*" >&2; }
info() { echo -e "${CYN}[*]${RST} $*"; }

# ---------------------------------------------------------------------------
# 0. checa ferramentas
# ---------------------------------------------------------------------------
precheck() {
    local falt=()
    command -v adb     >/dev/null || falt+=("adb")
    command -v fastboot >/dev/null || falt+=("fastboot")
    if [ ${#falt[@]} -gt 0 ]; then
        erro "faltam: ${falt[*]}"
        echo "    sudo apt update && sudo apt install -y adb fastboot"
        exit 1
    fi
    ok "adb e fastboot presentes"
}

# ---------------------------------------------------------------------------
# 1. detecta aparelho via adb
# ---------------------------------------------------------------------------
detect_adb() {
    info "procurando aparelho em modo ADB..."
    local serial
    serial=$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')
    if [ -z "$serial" ]; then
        warn "nenhum aparelho autorizado. Verifique:"
        echo "      - cabo USB de dados (nao so de carga)"
        echo "      - Depuracao USB ativa e popup 'permitir' aceito na tela"
        echo "      - 'adb kill-server && adb start-server' se o daemon travou"
        exit 1
    fi
    ok "aparelho: $serial"
    DEV_SERIAL="$serial"

    MODEL=$(adb -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
    CODENAME=$(adb -s "$serial" shell getprop ro.product.device 2>/dev/null | tr -d '\r')
    BUILD=$(adb -s "$serial" shell getprop ro.build.display.id 2>/dev/null | tr -d '\r')
    ANDROIDV=$(adb -s "$serial" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
    ARCH=$(adb -s "$serial" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')
    BOARD=$(adb -s "$serial" shell getprop ro.board.platform 2>/dev/null | tr -d '\r')
    HW=$(adb -s "$serial" shell getprop ro.hardware 2>/dev/null | tr -d '\r')
    MAGISK_INST=$(adb -s "$serial" shell pm list packages 2>/dev/null | grep -c "topjohnwu.magisk")

    echo
    echo -e "  ${CYN}modelo${RST}      $MODEL ($CODENAME)"
    echo -e "  ${CYN}build${RST}       $BUILD"
    echo -e "  ${CYN}android${RST}     $ANDROIDV | $ARCH"
    echo -e "  ${CYN}plataforma${RST}  $BOARD / $HW"
    if [ "$MAGISK_INST" -gt 0 ]; then ok "app Magisk ja instalado"; else warn "app Magisk NAO instalado"; fi
    echo

    # palpite do metodo por chipset
    case "$BOARD$HW" in
        *mt[0-9]*|*mtk*|*MT[0-9]*) info "chipset MediaTek detectado -> metodo 3 disponivel (mtkclient)";;
        *) info "chipset nao-MTK -> metodos 1 (Magisk/boot) ou 2 (TWRP)";;
    esac
}

# ---------------------------------------------------------------------------
# 2. estado do bootloader
# ---------------------------------------------------------------------------
check_unlock() {
    info "reiniciando em modo bootloader p/ ler estado..."
    adb -s "$DEV_SERIAL" reboot bootloader
    sleep 8
    local out
    out=$(fastboot getvar unlocked 2>&1)
    if echo "$out" | grep -qi "unlocked: yes"; then
        ok "bootloader ja destravado"
        UNLOCKED=1
    else
        warn "bootloader travado (ou nao reporta)"
        UNLOCKED=0
    fi
}

unlock_bootloader() {
    warn "OEM UNLOCK APAGA TODOS OS DADOS DO APARELHO. Continuar? (senha do Kali pode ser pedida)"
    read -r -p "[s/N] " resp
    [ "$resp" != "s" ] && { info "abortado."; exit 0; }
    fastboot flashing unlock || fastboot oem unlock
    ok "comando enviado — confirme no visor do aparelho (volume/power)"
    read -r -p "Enter quando o aparelho reiniciar e terminar o wipe..."
    UNLOCKED=1
}

# ---------------------------------------------------------------------------
# 3. metodo 1 — Magisk (patched boot.img)
# ---------------------------------------------------------------------------
magisk_root() {
    local stock=""
    if [ -n "${1:-}" ]; then stock="$1"; fi
    if [ -z "$stock" ]; then
        read -r -p "caminho do boot.img STOCK do seu build: " stock
    fi
    [ -f "$stock" ] || { erro "arquivo nao existe: $stock"; return 1; }

    info "empurrando boot.img pro aparelho (/sdcard/Download/)..."
    adb -s "$DEV_SERIAL" push "$stock" /sdcard/Download/stock_boot.img

    cat <<'EOF'

  Agora NO APARELHO:
    1. abra o app Magisk
    2. toque em "Install" > "Select and Patch a File"
    3. escolha stock_boot.img em Download
    4. aguarde o patch terminar (fica em Download como magisk_patched-*.img)
EOF
    read -r -p "Enter quando o patch terminar..."

    local patched
    patched=$(adb -s "$DEV_SERIAL" shell "ls /sdcard/Download/ | grep magisk_patched" | tr -d '\r' | head -1)
    if [ -z "$patched" ]; then
        # versoes novas salvam fora de Download
        patched=$(adb -s "$DEV_SERIAL" shell "find /sdcard -name 'magisk_patched*' 2>/dev/null" | tr -d '\r' | head -1)
    fi
    [ -z "$patched" ] && { erro "magisk_patched nao encontrado no aparelho"; return 1; }
    ok "achado: $patched"

    adb -s "$DEV_SERIAL" pull "$patched" ./magisk_patched.img
    info "reiniciando em bootloader e gravando boot..."
    adb -s "$DEV_SERIAL" reboot bootloader
    sleep 8
    fastboot flash boot magisk_patched.img
    fastboot reboot
    ok "boot gravado. Reiniciando..."
    sleep 20
    adb wait-for-device
    verify_root
}

# ---------------------------------------------------------------------------
# 4. metodo 2 — TWRP + Magisk.zip (sideload)
# ---------------------------------------------------------------------------
twrp_root() {
    local twrp zip
    read -r -p "caminho do TWRP .img: " twrp
    read -r -p "caminho do Magisk .zip: " zip
    [ -f "$twrp" ] || { erro "twrp nao existe"; return 1; }
    [ -f "$zip" ]  || { erro "magisk zip nao existe"; return 1; }

    adb -s "$DEV_SERIAL" reboot bootloader
    sleep 8
    info "dando boot no TWRP (sem gravar recovery)..."
    fastboot boot "$twrp"
    warn "quando o TWRP abrir, entre em Advanced > ADB Sideload e deslise"
    read -r -p "Enter quando o sideload estiver aguardando..."
    adb -s "$DEV_SERIAL" wait-for-recovery 2>/dev/null
    adb -s "$DEV_SERIAL" sideload "$zip"
    ok "zip enviado. Reiniciando sistema..."
    adb -s "$DEV_SERIAL" reboot
    sleep 20
    adb wait-for-device
    verify_root
}

# ---------------------------------------------------------------------------
# 5. metodo 3 — MediaTek (mtkclient)
# ---------------------------------------------------------------------------
mtk_root() {
    command -v mtk >/dev/null || command -v mtk.py >/dev/null || {
        erro "mtkclient nao instalado:"
        echo "    pip install mtkclient   (ou: git clone https://github.com/bkerler/mtkclient)"
        return 1
    }
    local patched
    read -r -p "caminho do boot.img JA PATCHED pelo Magisk: " patched
    [ -f "$patched" ] || { erro "arquivo nao existe"; return 1; }
    warn "aparelho DESLIGADO, segure VOL+ e VOL- e conecte o cabo (modo BROM)"
    read -r -p "Enter quando conectado em BROM..."
    info "gravando boot via exploit BROM..."
    sudo mtk w boot "$patched"
    ok "gravado. Ligue o aparelho normalmente."
    sleep 25
    adb wait-for-device 2>/dev/null
    verify_root
}

# ---------------------------------------------------------------------------
# 6. verificacao de root
# ---------------------------------------------------------------------------
verify_root() {
    info "verificando root..."
    sleep 5
    if adb -s "$DEV_SERIAL" shell pm list packages 2>/dev/null | grep -q topjohnwu.magisk; then
        ok "Magisk presente no sistema"
    fi
    warn "se aparecer popup do Magisk no aparelho, conceda 'permitir sempre'"
    local id
    id=$(adb -s "$DEV_SERIAL" shell "su -c id" 2>/dev/null | tr -d '\r')
    if echo "$id" | grep -q "uid=0"; then
        echo -e "${GRN}"
        echo "  ============================================"
        echo "   ROOT CONFIRMADO: $id"
        echo "  ============================================"
        echo -e "${RST}"
    else
        warn "su nao respondeu uid=0 ainda — pode ser popup pendente no aparelho"
        warn "rode manualmente: adb shell su -c id"
    fi
}

# ---------------------------------------------------------------------------
menu() {
    banner
    precheck
    detect_adb
    echo -e "${MAG}== metodos ==${RST}"
    echo "  1) Magisk + boot.img patchado (universal, precisa stock boot)"
    echo "  2) TWRP + Magisk.zip (sideload)"
    echo "  3) MediaTek BROM via mtkclient (sem destravar bootloader)"
    echo "  s) sair"
    echo
    read -r -p "escolha: " op
    case "$op" in
        1)
            check_unlock
            [ "$UNLOCKED" = "0" ] && unlock_bootloader
            magisk_root "${2:-}"
            ;;
        2)
            check_unlock
            [ "$UNLOCKED" = "0" ] && unlock_bootloader
            twrp_root
            ;;
        3) mtk_root ;;
        s|S) info "ate a proxima. ENI & LO."; exit 0 ;;
        *) erro "opcao invalida"; exit 1 ;;
    esac
}

menu "$@"
