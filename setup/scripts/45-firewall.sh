#!/usr/bin/env bash
# Apre in ufw le porte dei motori alle reti docker autorizzate.
#
# Perche' serve: ufw e' attivo con DEFAULT_INPUT_POLICY=DROP. I pacchetti
# che partono da un bridge docker verso un indirizzo dell'host entrano
# nella catena INPUT e vengono scartati, quindi i container non
# raggiungono i motori nonostante siano in ascolto. Le porte pubblicate da
# altri container invece funzionano, perche' passano per le catene di
# docker (FORWARD/DNAT) e saltano INPUT: e' questa asimmetria che rende il
# sintomo difficile da leggere.
#
# Due livelli di accesso, di proposito:
#   - la rete della dashboard ottiene tutte le porte, perche' il banco di
#     prova deve poter confrontare gateway e motore diretto;
#   - le reti dei progetti ottengono il solo gateway LiteLLM, che e' il
#     punto in cui vivono routing per nome modello, budget e fallback.
#     Dare a un progetto la porta diretta significa aggirare tutto questo.
#
#   sudo ./45-firewall.sh              aggiunge le regole e verifica
#   sudo ./45-firewall.sh --remove     le rimuove
#
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
load_env "$ROOT"
need_root
need_cmd ufw

REMOVE=0
for a in "$@"; do
  case "$a" in
    --remove) REMOVE=1 ;;
    *) die "argomento non riconosciuto: $a (previsto --remove)" ;;
  esac
done

LAB_NET="${LAB_NET:-aes-inference-lab_default}"
LAB_SUBNET_FALLBACK="${LAB_SUBNET_FALLBACK:-172.28.0.0/24}"
# Subnet autorizzate sulle porte dirette, separate da virgola, da .env.
# Sono la fonte di verita' quando docker non e' ispezionabile e comunque
# si aggiungono a quella della dashboard: i bridge dei progetti esistono
# anche quando il container della dashboard e' spento.
DOCKER_SUBNETS="${DOCKER_SUBNETS:-$LAB_SUBNET_FALLBACK}"
# Reti dei progetti che consumano l'inferenza. Spazio-separate, da .env.
GATEWAY_CLIENT_NETS="${GATEWAY_CLIENT_NETS:-}"
LAB_IMAGE="${LAB_IMAGE:-aes-inference-lab:latest}"

# La regola e' sempre sulla subnet, non sul nome del bridge: br-<hash>
# cambia a ogni ricreazione della rete e la regola smetterebbe di
# combaciare in silenzio. Per lo stesso motivo la subnet della dashboard
# e' fissata in docker-compose.yml.
subnet_of() {  # nome-rete → subnet, vuoto se non ispezionabile
  command -v docker >/dev/null 2>&1 || return 0
  docker network inspect "$1" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true
}

# ── Reti ─────────────────────────────────────────────────────
step "Reti"
LAB_SUBNET="$(subnet_of "$LAB_NET")"
if [[ -z "$LAB_SUBNET" ]]; then
  LAB_SUBNET="$LAB_SUBNET_FALLBACK"
  warn "rete $LAB_NET non ispezionabile: uso il valore di docker-compose.yml ($LAB_SUBNET)"
else
  ok "dashboard  $LAB_NET -> $LAB_SUBNET"
fi

# Insieme delle sorgenti ammesse sulle porte dirette: la dashboard piu'
# DOCKER_SUBNETS, deduplicato perche' le due liste si sovrappongono spesso.
DIRECT_SUBNETS=()
add_subnet() {
  local s="$1" x
  [[ -n "$s" ]] || return 0
  for x in "${DIRECT_SUBNETS[@]+"${DIRECT_SUBNETS[@]}"}"; do [[ "$x" == "$s" ]] && return 0; done
  DIRECT_SUBNETS+=("$s")
}
add_subnet "$LAB_SUBNET"
IFS=, read -r -a _cfg_subnets <<< "$DOCKER_SUBNETS"
for sub in "${_cfg_subnets[@]+"${_cfg_subnets[@]}"}"; do
  sub="${sub//[[:space:]]/}"
  [[ -n "$sub" ]] || continue
  [[ "$sub" == */* ]] || { warn "DOCKER_SUBNETS: '$sub' non e' una subnet CIDR, la salto"; continue; }
  add_subnet "$sub"
done
ok "sorgenti ammesse sulle porte dirette: ${DIRECT_SUBNETS[*]}"

CLIENT_NAMES=() CLIENT_SUBNETS=()
for net in $GATEWAY_CLIENT_NETS; do
  sub="$(subnet_of "$net")"
  if [[ -z "$sub" ]]; then
    warn "rete '$net' non trovata: salto (elencata in GATEWAY_CLIENT_NETS)"
    continue
  fi
  CLIENT_NAMES+=("$net"); CLIENT_SUBNETS+=("$sub")
  ok "progetto   $net -> $sub"
done
[[ ${#CLIENT_NAMES[@]} -eq 0 ]] && warn "nessuna rete progetto: valorizza GATEWAY_CLIENT_NETS in .env per dare il gateway ai container dei progetti"

# ── Stato di ufw ─────────────────────────────────────────────
step "Stato di ufw"
if ufw status | head -1 | grep -q inactive; then
  warn "ufw inattivo: niente blocca il traffico, le regole restano solo memorizzate"
else
  ok "$(ufw status | head -1)"
fi

# ── Porte ────────────────────────────────────────────────────
PORTS=(
  "${PORT_LITELLM}:gateway LiteLLM"
  "${PORT_COLIBRI}:colibri (direct)"
  "${PORT_LLAMA_SWAP}:llama-swap (direct)"
  "${PORT_EMBED}:llama-embed (direct)"
)

rule() {  # subnet porta etichetta
  local sub="$1" port="$2" label="$3"
  if (( REMOVE )); then
    ufw delete allow from "$sub" to any port "$port" proto tcp >/dev/null 2>&1 \
      && ok "rimossa   $sub -> $port  ($label)" \
      || warn "nessuna regola da rimuovere: $sub -> $port ($label)"
  else
    # ufw e' idempotente: una regola identica non viene duplicata.
    ufw allow from "$sub" to any port "$port" proto tcp \
      comment "aes-inference-lab: $label" >/dev/null \
      && ok "consentita $sub -> $port  ($label)"
  fi
}

step "Regole — porte dirette (dashboard e subnet docker)"
for entry in "${PORTS[@]}"; do
  IFS=: read -r port label <<< "$entry"
  [[ -n "$port" ]] || { warn "porta non definita per '$label': salto"; continue; }
  for sub in "${DIRECT_SUBNETS[@]}"; do
    rule "$sub" "$port" "$label"
  done
done

if [[ ${#CLIENT_NAMES[@]} -gt 0 ]]; then
  step "Regole — progetti (solo gateway)"
  if [[ -z "${PORT_LITELLM:-}" ]]; then
    warn "PORT_LITELLM non definita: nessuna regola per i progetti"
  else
    for i in "${!CLIENT_NAMES[@]}"; do
      rule "${CLIENT_SUBNETS[$i]}" "$PORT_LITELLM" "gateway <- ${CLIENT_NAMES[$i]}"
    done
  fi
fi

# ── Regole orfane ────────────────────────────────────────────
# Il bug che questa sezione esiste per cogliere: una regola aperta su una
# porta che nessun servizio usa piu'. Succede appena PORT_* cambia in .env
# (es. llama-swap spostata da 8081 a 8083 perche' 8081 era occupata): la
# fase 45 apre la porta nuova, la vecchia resta aperta verso il vuoto e la
# nuova sembra non funzionare. Porte e regole devono venire dalle STESSE
# variabili, quindi qui si rimuove tutto cio' che non corrisponde piu'.
if ! (( REMOVE )); then
  step "Regole orfane"
  VALID_PORTS=()
  for entry in "${PORTS[@]}"; do
    IFS=: read -r port _ <<< "$entry"
    [[ -n "$port" ]] && VALID_PORTS+=("$port")
  done
  # In ordine decrescente: cancellare per numero rinumera le regole sotto.
  mapfile -t ORPHANS < <(
    ufw status numbered 2>/dev/null \
      | grep -F 'aes-inference-lab:' \
      | sed -nE 's/^\[[[:space:]]*([0-9]+)\][[:space:]]+([0-9]+)\/tcp.*/\1 \2/p' \
      | sort -rn
  )
  found=0
  for line in "${ORPHANS[@]+"${ORPHANS[@]}"}"; do
    num="${line%% *}" port="${line##* }"
    for v in "${VALID_PORTS[@]}"; do [[ "$port" == "$v" ]] && { port=""; break; }; done
    [[ -n "$port" ]] || continue
    found=1
    warn "porta $port aperta ma nessun servizio la usa: rimuovo la regola [$num]"
    ufw --force delete "$num" >/dev/null && ok "rimossa la regola orfana sulla $port"
  done
  (( found )) || ok "nessuna regola orfana: le porte aperte combaciano con PORT_*"
fi

(( REMOVE )) && { ok "regole rimosse"; exit 0; }

# ── Diagnosi: chi ascolta davvero, e su quale indirizzo ───────
# Una regola ufw su una porta legata a 127.0.0.1 non serve a niente: il
# container non raggiunge il loopback dell'host in nessuna configurazione.
step "Ascolto effettivo"
LOOPBACK_ONLY=()
for entry in "${PORTS[@]}"; do
  IFS=: read -r port label <<< "$entry"
  [[ -n "$port" ]] || continue
  addrs=$(ss -tlnH "sport = :$port" | awk '{print $4}' | paste -sd' ')
  if [[ -z "$addrs" ]]; then
    warn "$port  ($label) nessuno in ascolto — servizio non avviato"
  elif grep -qE '(^| )(127\.0\.0\.1|\[::1\]):' <<< " $addrs" \
       && ! grep -qE '(^| )(0\.0\.0\.0|\*|\[::\]):' <<< " $addrs"; then
    warn "$port  ($label) solo loopback ($addrs): NON raggiungibile dai container"
    LOOPBACK_ONLY+=("$port")
  else
    ok "$port  ($label) $addrs"
  fi
done

# ── Verifica dal vivo ────────────────────────────────────────
probe() {  # descrizione comando-docker...
  local desc="$1"; shift
  local code; code=$("$@" 2>/dev/null || true)
  case "$code" in
    000|"") warn "$desc non raggiungibile" ;;
    *)      ok   "$desc HTTP $code" ;;
  esac
}

step "Verifica dalla dashboard"
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx inference-lab; then
  warn "container 'inference-lab' non in esecuzione: verifica saltata"
else
  for entry in "${PORTS[@]}"; do
    IFS=: read -r port label <<< "$entry"
    [[ -n "$port" ]] || continue
    probe "$port  ($label)" docker exec inference-lab sh -c \
      "curl -s -m 5 -o /dev/null -w '%{http_code}' http://host.docker.internal:$port/v1/models"
  done
fi

if [[ ${#CLIENT_NAMES[@]} -gt 0 && -n "${PORT_LITELLM:-}" ]]; then
  step "Verifica dalle reti dei progetti"
  if ! docker image inspect "$LAB_IMAGE" >/dev/null 2>&1; then
    warn "immagine $LAB_IMAGE assente: verifica saltata (serve un container con curl)"
  else
    for net in "${CLIENT_NAMES[@]}"; do
      # Container usa-e-getta sulla rete del progetto: e' il solo modo di
      # provare il percorso reale senza dipendere dagli strumenti presenti
      # nelle immagini dei progetti, che spesso non hanno curl.
      probe "$net -> gateway $PORT_LITELLM" \
        docker run --rm --network "$net" \
          --add-host host.docker.internal:host-gateway "$LAB_IMAGE" \
          sh -c "curl -s -m 5 -o /dev/null -w '%{http_code}' http://host.docker.internal:$PORT_LITELLM/v1/models"
    done
  fi
fi

if (( ${#LOOPBACK_ONLY[@]} )); then
  step "Da sistemare"
  warn "porte solo su loopback: ${LOOPBACK_ONLY[*]}"
  warn "imposta BIND_ADDR=0.0.0.0 in .env e rilancia la fase 40."
fi

ok "firewall configurato"
