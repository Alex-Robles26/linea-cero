#!/usr/bin/env bash
# Crea la máquina gratuita (Always Free) de los servidores de Línea Cero desde Oracle Cloud Shell,
# reintentando cada minuto en todas las zonas hasta que Oracle tenga capacidad.
#   curl -fsSL https://raw.githubusercontent.com/Alex-Robles26/linea-cero/main/servidor/crear_vm.sh | bash
#
# Solo usa recursos del plan gratuito: VM.Standard.A1.Flex (4 OCPU / 24 GB, el máximo gratis),
# disco de arranque por defecto, la red "lineacero-red" ya creada. No cambia nada de la cuenta.
set -uo pipefail

NAME="lineacero"
# Tamaños a probar, del mayor al menor ("núcleos:GB"); la máquina se puede ampliar después sin perder nada.
SIZES="${SIZES:-4:24 2:12 1:6}"
PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEQ+D91Q9Ktym/ZwCBErbyqGTJ+TzaCP1Oa46nDZQGYW lineacero-servidor"
T="${OCI_TENANCY:?Ejecuta esto en Oracle Cloud Shell}"

existing=$(oci compute instance list -c "$T" --display-name "$NAME" --query "data[?\"lifecycle-state\"!='TERMINATED'].id | [0]" --raw-output 2>/dev/null)
if [ -n "$existing" ] && [ "$existing" != "null" ]; then
  echo "Ya existe la máquina $NAME: $existing"; exit 0
fi

SUBNET=$(oci network subnet list -c "$T" --query "data[?contains(\"display-name\", 'public subnet-lineacero-red')].id | [0]" --raw-output)
IMAGE=$(oci compute image list -c "$T" --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
  --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC --query "data[0].id" --raw-output)
mapfile -t ADS < <(oci iam availability-domain list -c "$T" --query "data[].name" --raw-output | tr -d '[]", ' | grep -v '^$')
[ -n "$SUBNET" ] && [ "$SUBNET" != "null" ] || { echo "No encuentro la subred pública de lineacero-red"; exit 1; }
[ -n "$IMAGE" ] && [ "$IMAGE" != "null" ] || { echo "No encuentro la imagen de Ubuntu 24.04 ARM"; exit 1; }
echo "Subred: $SUBNET"; echo "Imagen: $IMAGE"; echo "Zonas: ${ADS[*]}"

echo "$PUBKEY" > ~/lineacero_key.pub
cat > ~/lineacero_init.sh <<'EOF'
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/Alex-Robles26/linea-cero/main/servidor/instalar.sh | bash
EOF

try=0
while true; do
  for SIZE in $SIZES; do
  OCPUS="${SIZE%%:*}"; MEM="${SIZE##*:}"
  for AD in "${ADS[@]}"; do
    try=$((try + 1))
    echo "[$(date +%H:%M:%S)] Intento $try en $AD ($OCPUS OCPU / $MEM GB)..."
    out=$(oci compute instance launch -c "$T" --availability-domain "$AD" --display-name "$NAME" \
      --shape VM.Standard.A1.Flex --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEM}" \
      --image-id "$IMAGE" --subnet-id "$SUBNET" --assign-public-ip true \
      --ssh-authorized-keys-file ~/lineacero_key.pub --user-data-file ~/lineacero_init.sh 2>&1)
    if echo "$out" | grep -q '"lifecycle-state"'; then
      id=$(echo "$out" | grep -m1 '"id": "ocid1.instance' | sed 's/.*"\(ocid1[^"]*\)".*/\1/')
      echo "¡CREADA! $id"
      sleep 60
      oci compute instance list-vnics --instance-id "$id" --query "data[0].\"public-ip\"" --raw-output | sed 's/^/IP pública: /'
      exit 0
    fi
    echo "$out" | grep -o '"message": "[^"]*"' | head -1
    if ! echo "$out" | grep -qi 'capacity\|TooManyRequests\|429'; then
      echo "Error que no es de capacidad, me detengo:"; echo "$out" | tail -20; exit 1
    fi
    sleep 10
  done
  done
  sleep 20
done
