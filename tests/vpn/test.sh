#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1
DBUS_NAME=org.freedesktop.resolve1
ORIG_DIR=$(pwd)

VPN_SETTINGS="ca = /etc/openvpn/client/ca.crt, cipher = AES-256-CBC, connection-type = tls, cert = /etc/openvpn/client/dummy.crt, key = /etc/openvpn/client/dummy.key, port = 1194, remote = 192.168.6.30"

rlJournalStart
    rlPhaseStartSetup
        rlRun "tmp=\$(mktemp -d)" 0 "Create tmp directory"
        rlRun "pushd $tmp"
        rlRun "set -o pipefail"
        rlRun "podman network create dnsconfd_network --internal -d=bridge  --gateway=192.168.6.1 --subnet=192.168.6.0/24"
        rlRun "podman network create dnsconfd_network2 --internal -d=bridge --gateway=192.168.7.1 --subnet=192.168.7.0/24"
        # dns=none is neccessary, because otherwise resolv.conf is created and
        # mounted by podman as read-only
        rlRun "dhcp_cid=\$(podman run -d --cap-add=NET_RAW --network dnsconfd_network:ip=192.168.6.20 localhost/dnsconfd_utilities:latest dhcp_entry.sh /etc/dhcp/dhcpd-common.conf)" 0 "Starting dhcpd container"
        rlRun "vpn_cid=\$(podman run -d --cap-add=NET_ADMIN --cap-add=NET_RAW --privileged --security-opt label=disable --device=/dev/net/tun --network dnsconfd_network:ip=192.168.6.30 --network dnsconfd_network2:ip=192.168.7.3 localhost/dnsconfd_utilities:latest vpn_entry.sh)"
        rlRun "dnsconfd_cid=\$(podman run -d --cap-add=NET_ADMIN --cap-add=NET_RAW --security-opt label=disable --device=/dev/net/tun --dns='none' --network dnsconfd_network:ip=192.168.6.2 dnsconfd_testing:latest)" 0 "Starting dnsconfd container"
        rlRun "dnsmasq1_cid=\$(podman run -d --dns='none' --network dnsconfd_network:ip=192.168.6.3 localhost/dnsconfd_utilities:latest dnsmasq_entry.sh --listen-address=192.168.6.3 --address=/first-address.test.com/192.168.6.3)" 0 "Starting first dnsmasq container"
        rlRun "dnsmasq2_cid=\$(podman run -d --dns='none' --network dnsconfd_network:ip=192.168.6.4 localhost/dnsconfd_utilities:latest dnsmasq_entry.sh --listen-address=192.168.6.4 --address=/second-address.test.com/192.168.6.4)" 0 "Starting second dnsmasq container"
        rlRun "dnsmasq3_cid=\$(podman run -d --dns='none' --network dnsconfd_network2:ip=192.168.7.2 localhost/dnsconfd_utilities:latest dnsmasq_entry.sh --listen-address=192.168.7.2 --address=/dummy.vpndomain.com/192.168.6.5)" 0 "Starting third dnsmasq container"
    rlPhaseEnd

    rlPhaseStartTest
        rlRun "podman exec $vpn_cid /bin/bash -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'" 0 "enable ip forwarding on vpn server"
        # easier to enable this on both than to find out which one is correct
        rlRun "podman exec $vpn_cid iptables -t nat -I POSTROUTING -o eth0 -j MASQUERADE" 0 "enable masquerade on vpn server eth0"
        rlRun "podman exec $vpn_cid iptables -t nat -I POSTROUTING -o eth1 -j MASQUERADE" 0 "enable masquerade on vpn server eth1"
        sleep 2
        rlRun "podman exec $dnsconfd_cid nmcli connection mod eth0 connection.autoconnect yes ipv4.gateway '' ipv4.addr '' ipv4.method auto" 0 "Setting eth0 to autoconfiguration"
        sleep 2
        rlRun "podman exec $dnsconfd_cid dnsconfd --dbus-name=$DBUS_NAME status --json > status1" 0 "Getting status of dnsconfd"
        rlRun "cat status1"
        rlAssertNotDiffer status1 $ORIG_DIR/expected_status1.json
        rlRun "podman exec $dnsconfd_cid getent hosts first-address.test.com | grep 192.168.6.3" 0 "Verifying correct address resolution"
        rlRun "podman exec $dnsconfd_cid getent hosts second-address.test.com | grep 192.168.6.4" 0 "Verifying correct address resolution"
        rlRun "podman exec $dnsconfd_cid getent hosts second-address | grep 192.168.6.4" 0 "Verifying correct address resolution"
        ### now connect to VPN
        rlRun "podman exec $vpn_cid bash -c 'cd /etc/openvpn/easy-rsa && ./easyrsa --no-pass --batch build-client-full dummy'"
        rlRun "podman cp $vpn_cid:/etc/openvpn/easy-rsa/pki/issued/dummy.crt $dnsconfd_cid:/etc/openvpn/client/dummy.crt"
        rlRun "podman cp $vpn_cid:/etc/openvpn/easy-rsa/pki/private/dummy.key $dnsconfd_cid:/etc/openvpn/client/dummy.key"
        rlRun "podman cp $vpn_cid:/etc/openvpn/easy-rsa/pki/ca.crt $dnsconfd_cid:/etc/openvpn/client/ca.crt"
        rlRun "podman exec $dnsconfd_cid nmcli connection add type vpn vpn-type openvpn ipv4.method auto ipv4.never-default yes vpn.data '$VPN_SETTINGS'" 0 "Creating vpn connection"
        rlRun "podman exec $dnsconfd_cid nmcli connection up vpn" 0 "Connecting to vpn"
        sleep 2
        rlRun "podman exec $dnsconfd_cid dnsconfd --dbus-name=$DBUS_NAME status --json > status2" 0 "Getting status of dnsconfd"
        rlRun "cat status2"
        rlAssertNotDiffer status2 $ORIG_DIR/expected_status2.json
        rlRun "podman exec $dnsconfd_cid getent hosts dummy | grep 192.168.6.5" 0 "Verifying correct address resolution"
        rlRun "podman exec $dnsconfd_cid getent hosts second-address | grep 192.168.6.4" 0 "Verifying correct address resolution"
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "podman exec $dnsconfd_cid journalctl -u dnsconfd" 0 "Saving dnsconfd logs"
        rlRun "podman exec $dnsconfd_cid journalctl -u unbound" 0 "Saving unbound logs"
        rlRun "podman exec $dnsconfd_cid ip route" 0 "Saving present routes"
        rlRun "popd"
        rlRun "podman stop -t 2 $dnsconfd_cid $dnsmasq1_cid $dnsmasq2_cid $dnsmasq3_cid $dhcp_cid $vpn_cid" 0 "Stopping containers"
        rlRun "podman container rm $dnsconfd_cid $dnsmasq1_cid $dnsmasq2_cid $dnsmasq3_cid $dhcp_cid $vpn_cid" 0 "Removing containers"
        rlRun "podman network rm dnsconfd_network dnsconfd_network2" 0 "Removing networks"
        rlRun "rm -r $tmp" 0 "Remove tmp directory"
    rlPhaseEnd
rlJournalEnd
