#!/usr/bin/env bash
# Pakettest der Noxis-Firewall in isolierten Netz-Namespaces (ändert nichts am Host-Netz).
# Braucht: root, iproute2, nftables, python3.     sudo ./test/test_firewall.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NFT="$ROOT/noxis-opsec/etc/noxis/firewall.nft"
P=nxphone; N=nxnet
pass=0; fail=0
ok() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
no() { if eval "$2" >/dev/null 2>&1; then echo "FAIL $1"; fail=$((fail+1)); else echo "PASS $1"; pass=$((pass+1)); fi; }
cleanup() { ip netns del $P 2>/dev/null; ip netns del $N 2>/dev/null; }
trap cleanup EXIT
cleanup

ip netns add $P; ip netns add $N
ip link add v-phone type veth peer name v-net
ip link set v-phone netns $P; ip link set v-net netns $N
ip -n $P addr add 10.9.0.2/24 dev v-phone; ip -n $N addr add 10.9.0.1/24 dev v-net
for ns in $P $N; do ip -n $ns link set lo up; done
ip -n $P link set v-phone up; ip -n $N link set v-net up
ip -n $P route add default via 10.9.0.1
ip -n $P link add wg0-mullvad type dummy
ip -n $P addr add 10.64.0.2/32 dev wg0-mullvad
ip -n $P link set wg0-mullvad up
ip -n $P route add 10.64.0.0/16 dev wg0-mullvad
ip netns exec $N sysctl -qw net.ipv4.ip_forward=1

# "Internet": Server im Netz-Namespace
ip netns exec $N python3 -c '
import socket,threading
def tcp():
    s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("0.0.0.0",8080)); s.listen()
    while True: c,_=s.accept(); c.close()
def udp():
    u=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); u.bind(("0.0.0.0",9999))
    while True:
        d,a=u.recvfrom(100); open("/tmp/nx-udp-recv","a").write(d.decode()+"\n")
threading.Thread(target=tcp,daemon=True).start(); udp()' &
SRV=$!
ip netns exec $P python3 -c '
import socket
s=socket.socket(); s.bind(("0.0.0.0",22)); s.listen()
while True: c,_=s.accept(); c.close()' &
SSHD=$!
sleep 0.5; rm -f /tmp/nx-udp-recv

tcp_from_phone() { ip netns exec $P python3 -c 'import socket; socket.create_connection(("10.9.0.1",8080),timeout=2)'; }
ok "ohne Firewall: Verbindung ins Netz geht (Kontrolle)" tcp_from_phone

ip netns exec $P nft -f "$NFT" || { echo "Regelwerk lädt nicht"; exit 1; }
ok "Regelwerk geladen" "ip netns exec $P nft list table inet noxis"

no "ausgehend TCP am Tunnel vorbei blockiert" tcp_from_phone
no "DNS-over-TLS (9.9.9.9:853) am Tunnel vorbei blockiert" \
   "ip netns exec $P python3 -c 'import socket; socket.create_connection((\"9.9.9.9\",853),timeout=2)'"
ok "UDP in den Tunnel (wg0-mullvad) erlaubt" \
   "ip netns exec $P python3 -c 'import socket; socket.socket(socket.AF_INET,socket.SOCK_DGRAM).sendto(b\"x\",(\"10.64.0.1\",51820))'"
ip netns exec $P python3 -c '
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,36,0x6d6f6c65)
s.sendto(b"mullvad-relay",("10.9.0.1",9999))' 2>/dev/null; sleep 0.5
ok "Mullvad-Relay-Verkehr (fwmark 0x6d6f6c65) erlaubt" "grep -q mullvad-relay /tmp/nx-udp-recv"
ip netns exec $P python3 -c '
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.sendto(b"leak",("10.9.0.1",9999))' 2>/dev/null; sleep 0.5
no "UDP ohne Mullvad-Markierung kommt nicht an" "grep -q leak /tmp/nx-udp-recv"
no "eingehend: SSH-Port aus dem Netz nicht erreichbar" \
   "ip netns exec $N python3 -c 'import socket; socket.create_connection((\"10.9.0.2\",22),timeout=2)'"
no "eingehend: Ping wird verworfen" "ip netns exec $N ping -c1 -W1 10.9.0.2"
ok "lokal (loopback) funktioniert" "ip netns exec $P python3 -c 'import socket; socket.create_connection((\"127.0.0.1\",22),timeout=2)'"

kill $SRV $SSHD 2>/dev/null; rm -f /tmp/nx-udp-recv
echo; echo "$pass bestanden, $fail fehlgeschlagen"
[ "$fail" -eq 0 ]
