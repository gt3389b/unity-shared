#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Create/delete mac80211_hwsim radios over generic netlink, in the CALLER's
network namespace.

Why: OrbStack machines share one VM kernel and each machine is a netns that is
not init_net. mac80211_hwsim's module-parameter radios (radios=N) are created in
init_net and are invisible inside a machine; radios created with
HWSIM_CMD_NEW_RADIO land in the requesting socket's netns, which is also what a
test harness with one namespace per device needs. No dependencies beyond the stdlib.

  hwsim_radio.py new [--name NAME] [--channels N] [--perm-addr MAC] [--p2p]
  hwsim_radio.py del RADIO_ID
  hwsim_radio.py family          # print resolved family id

`new` prints the radio id (the kernel returns it as the netlink ack value).
Enum values are from linux-7.0.14 drivers/net/wireless/virtual/mac80211_hwsim.h.

Namespace rules (verified on OrbStack 2.2.3 / 7.0.14):
  * A radio belongs to the hwsim "netgroup" of the netns that CREATED it; that
    never changes, even after `iw phy <phy> set netns ...`. Radios exchange
    frames only within a netgroup, and wmediumd must register from that
    netns. So: create every radio of one simulated "air" from one
    netns, then hand the wiphys out to the AP and station namespaces.
  * `del` is checked against the caller's netns, so delete a radio from the
    netns it currently lives in (`ip netns exec <ns> hwsim_radio.py del ID`),
    and do it BEFORE deleting that netns — cfg80211 moves orphaned wiphys back
    to init_net, where the machine cannot reach them.
"""
import argparse
import os
import socket
import struct
import sys

NETLINK_GENERIC = 16
NLM_F_REQUEST, NLM_F_ACK = 0x1, 0x4
NLMSG_ERROR = 0x2
GENL_ID_CTRL = 0x10
CTRL_CMD_GETFAMILY = 3
CTRL_ATTR_FAMILY_ID, CTRL_ATTR_FAMILY_NAME = 1, 2

HWSIM_FAMILY = "MAC80211_HWSIM"
HWSIM_CMD_NEW_RADIO, HWSIM_CMD_DEL_RADIO = 4, 5
HWSIM_ATTR_CHANNELS = 9
HWSIM_ATTR_RADIO_ID = 10
HWSIM_ATTR_REG_HINT_ALPHA2 = 11
HWSIM_ATTR_REG_CUSTOM_REG = 12
HWSIM_ATTR_REG_STRICT_REG = 13
HWSIM_ATTR_SUPPORT_P2P_DEVICE = 14
HWSIM_ATTR_USE_CHANCTX = 15
HWSIM_ATTR_RADIO_NAME = 17
HWSIM_ATTR_PERM_ADDR = 22


def nla(attr_type: int, payload: bytes) -> bytes:
    hdr = struct.pack("=HH", 4 + len(payload), attr_type)
    pad = (-(4 + len(payload))) % 4
    return hdr + payload + b"\0" * pad


def nla_u32(t: int, v: int) -> bytes:
    return nla(t, struct.pack("=I", v))


def nla_flag(t: int) -> bytes:
    return nla(t, b"")


def nla_str(t: int, s: str) -> bytes:
    return nla(t, s.encode() + b"\0")


class Genl:
    def __init__(self) -> None:
        self.sock = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, NETLINK_GENERIC)
        self.sock.bind((0, 0))
        self.seq = 1

    def request(self, nl_type: int, cmd: int, attrs: bytes) -> tuple[int, bytes]:
        """Send one request; return (ack_error, payload_of_first_reply)."""
        self.seq += 1
        genl = struct.pack("=BBH", cmd, 1, 0)
        body = genl + attrs
        msg = struct.pack("=IHHII", 16 + len(body), nl_type, NLM_F_REQUEST | NLM_F_ACK, self.seq, 0) + body
        self.sock.send(msg)
        reply_payload = b""
        while True:
            data = self.sock.recv(65536)
            off = 0
            while off < len(data):
                ln, typ, flags, seq, pid = struct.unpack_from("=IHHII", data, off)
                payload = data[off + 16 : off + ln]
                if typ == NLMSG_ERROR:
                    (err,) = struct.unpack_from("=i", payload, 0)
                    return err, reply_payload
                reply_payload = payload
                off += (ln + 3) & ~3

    def family_id(self, name: str) -> int:
        err, payload = self.request(GENL_ID_CTRL, CTRL_CMD_GETFAMILY, nla_str(CTRL_ATTR_FAMILY_NAME, name))
        if err < 0:
            raise OSError(-err, f"CTRL_CMD_GETFAMILY {name}: {os.strerror(-err)}")
        off = 4  # skip genlmsghdr
        while off < len(payload):
            ln, typ = struct.unpack_from("=HH", payload, off)
            if typ == CTRL_ATTR_FAMILY_ID:
                return struct.unpack_from("=H", payload, off + 4)[0]
            off += (ln + 3) & ~3
        raise RuntimeError("family id not in reply")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    n = sub.add_parser("new")
    n.add_argument("--name")
    n.add_argument("--channels", type=int, default=1, help="concurrent channels (>1 enables chanctx)")
    n.add_argument("--perm-addr", help="permanent MAC, e.g. 02:00:00:00:01:00")
    n.add_argument("--p2p", action="store_true", help="advertise P2P-device support")
    n.add_argument("--reg-custom", type=int, metavar="IDX",
                   help="use hwsim's built-in custom regdom IDX (driver table hwsim_world_regdom_custom[]); "
                        "needed e.g. for 6 GHz AP, which the stock regdb marks NO-IR for most countries")
    n.add_argument("--reg-strict", action="store_true", help="ignore later regulatory hints (REGULATORY_STRICT_REG)")
    n.add_argument("--reg-alpha2", metavar="CC", help="initial regulatory hint, e.g. US")
    d = sub.add_parser("del")
    d.add_argument("radio_id", type=int)
    sub.add_parser("family")
    a = p.parse_args()

    g = Genl()
    fid = g.family_id(HWSIM_FAMILY)
    if a.cmd == "family":
        print(fid)
        return 0
    if a.cmd == "new":
        attrs = nla_u32(HWSIM_ATTR_CHANNELS, a.channels)
        if a.channels > 1:
            attrs += nla_flag(HWSIM_ATTR_USE_CHANCTX)
        if a.name:
            attrs += nla_str(HWSIM_ATTR_RADIO_NAME, a.name)
        if a.p2p:
            attrs += nla_flag(HWSIM_ATTR_SUPPORT_P2P_DEVICE)
        if a.perm_addr:
            attrs += nla(HWSIM_ATTR_PERM_ADDR, bytes.fromhex(a.perm_addr.replace(":", "")))
        if a.reg_custom is not None:
            attrs += nla_u32(HWSIM_ATTR_REG_CUSTOM_REG, a.reg_custom)
        if a.reg_strict:
            attrs += nla_flag(HWSIM_ATTR_REG_STRICT_REG)
        if a.reg_alpha2:
            attrs += nla(HWSIM_ATTR_REG_HINT_ALPHA2, a.reg_alpha2.encode()[:2])
        err, _ = g.request(fid, HWSIM_CMD_NEW_RADIO, attrs)
        if err < 0:
            print(f"HWSIM_CMD_NEW_RADIO failed: {os.strerror(-err)}", file=sys.stderr)
            return 1
        print(err)  # radio id
        return 0
    if a.cmd == "del":
        err, _ = g.request(fid, HWSIM_CMD_DEL_RADIO, nla_u32(HWSIM_ATTR_RADIO_ID, a.radio_id))
        if err < 0:
            print(f"HWSIM_CMD_DEL_RADIO {a.radio_id} failed: {os.strerror(-err)}", file=sys.stderr)
            return 1
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
