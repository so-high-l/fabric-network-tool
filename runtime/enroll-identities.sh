#!/usr/bin/env sh
set -eu

PLAN_FILE="${PLAN_FILE:-/config/identities.tsv}"
OUTPUT_ROOT="${OUTPUT_ROOT:-/work/out}"
PACKAGE_ROOT="${PACKAGE_ROOT:-/work/packages}"
CLIENT_ROOT="${CLIENT_ROOT:-/work/client-state}"
TAB="$(printf '\t')"

mkdir -p "$OUTPUT_ROOT" "$PACKAGE_ROOT" "$CLIENT_ROOT"

one_file() {
  directory="$1"
  set -- "$directory"/*
  [ "$#" -eq 1 ] && [ -f "$1" ] || {
    echo "Expected exactly one file in $directory" >&2
    exit 1
  }
  printf '%s' "$1"
}

bootstrap_value() {
  tr -d '\r\n' <"/bootstrap/$1/$2"
}

registration_value() {
  tr -d '\r\n' <"/registration/$1"
}

run_client() {
  ca_name="$1"
  shift
  FABRIC_CA_CLIENT_HOME="$CLIENT_ROOT/$ca_name" fabric-ca-client "$@"
}

run_enrollment_client() {
  client_ca_name="$1"
  client_identity="$2"
  client_profile="$3"
  shift 3
  FABRIC_CA_CLIENT_HOME="$CLIENT_ROOT/$client_ca_name/$client_identity/$client_profile" fabric-ca-client "$@"
}

enroll() {
  enroll_ca_name="$1"
  enroll_identity="$2"
  enroll_secret_value="$3"
  enroll_profile="$4"
  enroll_hosts="$5"
  enroll_destination="$6"
  enroll_root_cert="/ca-roots/$enroll_ca_name/tls.crt"

  mkdir -p "$enroll_destination"
  if [ "$enroll_profile" = tls ]; then
    printf 'Enrolling TLS identity=%s ca=%s hosts=%s\n' "$enroll_identity" "$enroll_ca_name" "$enroll_hosts"
    run_enrollment_client "$enroll_ca_name" "$enroll_identity" tls enroll \
      --url "https://${enroll_identity}:${enroll_secret_value}@${enroll_ca_name}:7054" \
      --mspdir "$enroll_destination" \
      --enrollment.profile tls \
      --csr.hosts "$enroll_hosts" \
      --tls.certfiles "$enroll_root_cert"
  else
    run_enrollment_client "$enroll_ca_name" "$enroll_identity" msp enroll \
      --url "https://${enroll_identity}:${enroll_secret_value}@${enroll_ca_name}:7054" \
      --mspdir "$enroll_destination" \
      --tls.certfiles "$enroll_root_cert"
  fi
}

register_node() {
  ca_name="$1"
  admin_msp="$2"
  identity="$3"
  identity_type="$4"
  identity_secret="$5"
  registration_output=''

  if registration_output="$(run_client "$ca_name" register \
    --url "https://${ca_name}:7054" \
    --mspdir "$admin_msp" \
    --id.name "$identity" \
    --id.secret "$identity_secret" \
    --id.type "$identity_type" \
    --id.maxenrollments -1 \
    --tls.certfiles "/ca-roots/$ca_name/tls.crt" 2>&1)"; then
    echo "Registered $identity with $ca_name"
    return
  fi

  case "$registration_output" in
    *"already registered"*)
      echo "Keeping existing registration for $identity"
      ;;
    *)
      echo "Registration failed for $identity at $ca_name" >&2
      exit 1
      ;;
  esac
}

package_msp() {
  secret_name="$1"
  identity_root="$2"
  admin_root="$3"
  destination="$PACKAGE_ROOT/$secret_name"
  mkdir -p "$destination"
  cp "$(one_file "$admin_root/msp/signcerts")" "$destination/admincerts"
  cp "$(one_file "$identity_root/msp/cacerts")" "$destination/cacerts"
  cp "$(one_file "$identity_root/msp/keystore")" "$destination/keystore"
  cp "$(one_file "$identity_root/msp/signcerts")" "$destination/signcerts"
  cp "$(one_file "$identity_root/tls/tlscacerts")" "$destination/tlscacerts"
}

package_tls() {
  secret_name="$1"
  identity_root="$2"
  role="$3"
  destination="$PACKAGE_ROOT/$secret_name"
  mkdir -p "$destination"
  cp "$(one_file "$identity_root/tls/tlscacerts")" "$destination/cacrt"
  if [ "$role" = admin ]; then
    cp "$(one_file "$identity_root/tls/signcerts")" "$destination/clientcrt"
    cp "$(one_file "$identity_root/tls/keystore")" "$destination/clientkey"
  elif [ "$role" = service ]; then
    cp "$(one_file "$identity_root/tls/tlscacerts")" "$destination/ca.crt"
    cp "$(one_file "$identity_root/tls/signcerts")" "$destination/client.crt"
    cp "$(one_file "$identity_root/tls/keystore")" "$destination/client.key"
  else
    cp "$(one_file "$identity_root/tls/signcerts")" "$destination/servercrt"
    cp "$(one_file "$identity_root/tls/keystore")" "$destination/serverkey"
  fi
}

echo 'Enrolling required organization administrators'
while IFS="$TAB" read -r record_kind ca_name identity identity_type msp_secret tls_secret hosts; do
  [ "$record_kind" = admin ] || continue
  admin_password="$(bootstrap_value "$ca_name" password)"
  expected_admin="$(bootstrap_value "$ca_name" username)"
  [ "$identity" = "$expected_admin" ] || {
    echo "Bootstrap username for $ca_name is not $identity" >&2
    exit 1
  }
  admin_root="$OUTPUT_ROOT/$ca_name/admin"
  enroll "$ca_name" "$identity" "$admin_password" msp '' "$admin_root/msp"
  enroll "$ca_name" "$identity" "$admin_password" tls "$hosts" "$admin_root/tls"
  package_msp "$msp_secret" "$admin_root" "$admin_root"
  package_tls "$tls_secret" "$admin_root" admin
done <"$PLAN_FILE"

echo 'Registering and enrolling required Fabric nodes and external services'
while IFS="$TAB" read -r record_kind ca_name identity identity_type msp_secret tls_secret hosts; do
  [ "$record_kind" = node ] || [ "$record_kind" = service ] || continue
  identity_secret="$(registration_value "$identity")"
  admin_root="$OUTPUT_ROOT/$ca_name/admin"
  identity_root="$OUTPUT_ROOT/$ca_name/identities/$identity"
  register_node "$ca_name" "$admin_root/msp" "$identity" "$identity_type" "$identity_secret"
  enroll "$ca_name" "$identity" "$identity_secret" msp '' "$identity_root/msp"
  enroll "$ca_name" "$identity" "$identity_secret" tls "$hosts" "$identity_root/tls"
  package_msp "$msp_secret" "$identity_root" "$admin_root"
  package_tls "$tls_secret" "$identity_root" "$record_kind"
done <"$PLAN_FILE"

touch /work/enrollment-complete
echo 'Fabric identity enrollment and local packaging completed.'
