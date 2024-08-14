#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1
DBUS_NAME=org.freedesktop.resolve1
ORIG_DIR=$(pwd)

rlJournalStart
    rlPhaseStartSetup
        rlRun "tmp=\$(mktemp -d)" 0 "Create tmp directory"
        rlRun "pushd $tmp"
        rlRun "set -o pipefail"
        rlRun "podman network create dnsconfd_network --internal -d=bridge --gateway=192.168.6.1 --subnet=192.168.6.0/24"
        # dns=none is neccessary, because otherwise resolv.conf is created and
        # mounted by podman as read-only
        rlRun "dnsconfd_cid=\$(podman run -d --dns='none' --network dnsconfd_network:ip=192.168.6.2 dnsconfd_testing:latest)" 0 "Starting dnsconfd container"
        rlRun "dnsmasq_cid=\$(podman run -d --dns='none' --network dnsconfd_network:ip=192.168.6.3 localhost/dnsconfd_utilities:latest dnsmasq_entry.sh --listen-address=192.168.6.3 --address=/address.test.com/192.168.6.3)" 0 "Starting dnsmasq container"
    rlPhaseEnd

    rlPhaseStartTest
        rlRun "podman exec $dnsconfd_cid /bin/bash -c 'echo listen_address: \"127.0.0.64\" >> /etc/dnsconfd.conf'" 0 "Change listen_address"
        rlRun "podman exec $dnsconfd_cid systemctl restart dnsconfd"
        sleep 7
        rlRun "podman exec $dnsconfd_cid nmcli connection mod eth0 ipv4.dns 192.168.6.3" 0 "Adding dns server to NM active profile"
        sleep 2
        rlRun "podman exec $dnsconfd_cid dnsconfd --dbus-name=$DBUS_NAME status --json > status1" 0 "Getting status of dnsconfd"
        rlAssertNotDiffer status1 $ORIG_DIR/expected_status.json
        rlRun "podman exec $dnsconfd_cid getent hosts address.test.com | grep 192.168.6.3" 0 "Verifying correct address resolution"
        rlRun "podman exec $dnsconfd_cid cat /etc/resolv.conf | grep '127.0.0.64'" 0 "Verifying correct listening address"
        rlRun "podman exec $dnsconfd_cid /bin/bash -c 'echo LISTEN_ADDRESS=\"127.0.0.32\" >> /etc/sysconfig/dnsconfd'" 0 "Setting service env file"
        rlRun "podman exec $dnsconfd_cid systemctl restart dnsconfd"
        sleep 7
        # we have to restart, otherwise NM will attempt to change ipv6 and because it has no permissions, it will fail
        rlRun "podman exec $dnsconfd_cid systemctl restart NetworkManager" 0 "Reactivating connection"
        sleep 3
        rlRun "podman exec $dnsconfd_cid getent hosts address.test.com | grep 192.168.6.3" 0 "Verifying correct address resolution"
        rlRun "podman exec $dnsconfd_cid cat /etc/resolv.conf | grep '127.0.0.32'" 0 "Verifying correct listening address"
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "podman exec $dnsconfd_cid journalctl -u dnsconfd" 0 "Saving dnsconfd logs"
        rlRun "podman exec $dnsconfd_cid journalctl -u unbound" 0 "Saving unbound logs"
        rlRun "podman exec $dnsconfd_cid ip route" 0 "Saving present routes"
        rlRun "popd"
        rlRun "podman stop -t 2 $dnsconfd_cid $dnsmasq_cid" 0 "Stopping containers"
        rlRun "podman container rm $dnsconfd_cid $dnsmasq_cid" 0 "Removing containers"
        rlRun "podman network rm dnsconfd_network" 0 "Removing networks"
        rlRun "rm -r $tmp" 0 "Remove tmp directory"
    rlPhaseEnd
rlJournalEnd