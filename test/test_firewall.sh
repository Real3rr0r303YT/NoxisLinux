#!/usr/bin/env bash
# Packet test of the Noxis firewall in isolated network namespaces (does not touch the host network).
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

# "internet": server in the network namespace
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
ok "without firewall: connection works (control)" tcp_from_phone

ip netns exec $P nft -f "$NFT" || { echo "ruleset does not load"; exit 1; }
ok "ruleset loaded" "ip netns exec $P nft list table inet noxis"

no "outbound TCP outside the tunnel blocked" tcp_from_phone
no "DNS-over-TLS (9.9.9.9:853) outside the tunnel blocked" \
   "ip netns exec $P python3 -c 'import socket; socket.create_connection((\"9.9.9.9\",853),timeout=2)'"
ok "UDP into the tunnel (wg0-mullvad) allowed" \
   "ip netns exec $P python3 -c 'import socket; socket.socket(socket.AF_INET,socket.SOCK_DGRAM).sendto(b\"x\",(\"10.64.0.1\",51820))'"
ip netns exec $P python3 -c '
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,36,0x6d6f6c65)
s.sendto(b"mullvad-relay",("10.9.0.1",9999))' 2>/dev/null; sleep 0.5
ok "Mullvad relay traffic (fwmark 0x6d6f6c65) allowed" "grep -q mullvad-relay /tmp/nx-udp-recv"
ip netns exec $P python3 -c '
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.sendto(b"leak",("10.9.0.1",9999))' 2>/dev/null; sleep 0.5
no "UDP without the Mullvad mark does not arrive" "grep -q leak /tmp/nx-udp-recv"
no "inbound: SSH port unreachable from the network" \
   "ip netns exec $N python3 -c 'import socket; socket.create_connection((\"10.9.0.2\",22),timeout=2)'"
no "inbound: ping dropped" "ip netns exec $N ping -c1 -W1 10.9.0.2"
ok "local (loopback) works" "ip netns exec $P python3 -c 'import socket; socket.create_connection((\"127.0.0.1\",22),timeout=2)'"

kill $SRV $SSHD 2>/dev/null; rm -f /tmp/nx-udp-recv
echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
