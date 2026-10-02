#!/usr/bin/env python3
"""Print LXMF backchannel behavior as JSON for Tests/LXMFTests/Fixtures/PythonBackchannelVectors.swift.

Drives the reference's own LXMRouter methods with stand-in links. The config it writes has no
interfaces and no shared instance; run it with the network denied as well:

    sandbox-exec -p '(version 1)(allow default)(deny network*)' \
        python3 scripts/capture-backchannel-vectors.py <empty-config-dir>

Needs rns and lxmf installed. The fixture was captured with RNS 1.5.5 and LXMF 1.2.0.
"""
import json
import os
import sys
import time

import RNS
from LXMF import LXMRouter, LXMessage
from importlib.metadata import version

cfg = sys.argv[1]
os.makedirs(cfg, exist_ok=True)
with open(os.path.join(cfg, "config"), "w") as f:
    f.write("[reticulum]\n  enable_transport = False\n  share_instance = No\n"
            "  panic_on_interface_error = No\n[logging]\n  loglevel = 2\n[interfaces]\n")
RNS.Reticulum(configdir=cfg, loglevel=RNS.LOG_CRITICAL)

LXMRouter.PROCESSING_INTERVAL = 3600

id_a = RNS.Identity.from_bytes(bytes(range(64)))
id_b = RNS.Identity.from_bytes(bytes(range(64, 128)))
id_c = RNS.Identity.from_bytes(bytes(range(128, 192)))


class StandInLink:
    def __init__(self, name, initiator, status, activated_at=None):
        self.name = name
        self.initiator = initiator
        self.status = status
        self.activated_at = activated_at
        self.link_id = os.urandom(16)
        self.identified_as = []
        self.configured = {}

    def identify(self, identity):
        self.identified_as.append(identity.get_public_key().hex())

    def track_phy_stats(self, track): self.configured["track_phy_stats"] = track
    def set_packet_callback(self, cb): self.configured["packet"] = cb.__name__
    def set_resource_strategy(self, s): self.configured["resource_strategy"] = s
    def set_resource_callback(self, cb): self.configured["resource"] = cb.__name__
    def set_resource_started_callback(self, cb): self.configured["resource_started"] = cb.__name__
    def set_resource_concluded_callback(self, cb): self.configured["resource_concluded"] = cb.__name__
    def set_remote_identified_callback(self, cb): self.configured["remote_identified"] = cb.__name__
    def no_data_for(self): return 0
    def teardown(self): self.status = RNS.Link.CLOSED


created_links = []


class NoNewLinks(RNS.Link):
    def __init__(self, *a, **k):
        created_links.append(a)
        raise RuntimeError("no new links in capture")


RNS.Link = NoNewLinks

storage = os.path.join(cfg, "lxmf")
router = LXMRouter(identity=id_a, storagepath=storage)
router.jobs = lambda: None
dest_a = router.register_delivery_identity(id_a)

path_requests = []
router.request_path = lambda h: path_requests.append(h.hex())

hash_a = RNS.Destination.hash_from_name_and_identity("lxmf.delivery", id_a)
hash_b = RNS.Destination.hash_from_name_and_identity("lxmf.delivery", id_b)
hash_c = RNS.Destination.hash_from_name_and_identity("lxmf.delivery", id_c)
out_b = RNS.Destination(id_b, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
src_c = RNS.Destination(id_c, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")


def reset():
    router.direct_links.clear()
    router.backchannel_links.clear()
    router.pending_outbound.clear()
    path_requests.clear()
    created_links.clear()


def message(method, source=dest_a, state=LXMessage.OUTBOUND, content="backchannel"):
    m = LXMessage(out_b, source, content, "t", desired_method=method)
    m.pack()
    m.state = state
    sent_on = []

    def send():
        sent_on.append(m._LXMessage__delivery_destination.name)
        m.state = LXMessage.SENDING
    m.send = send
    m.sent_on = sent_on
    router.pending_outbound.append(m)
    return m


v = {"rns": version("rns"), "lxmf": version("lxmf")}
v["identity_a_public_key"] = id_a.get_public_key().hex()
v["identity_b_public_key"] = id_b.get_public_key().hex()
v["delivery_hash_a"] = hash_a.hex()
v["delivery_hash_b"] = hash_b.hex()

# delivery_remote_identified (:2064-2067) and delivery_link_available (:769-771).
reset()
inbound_a = StandInLink("inbound_a", initiator=False, status=RNS.Link.ACTIVE)
inbound_b = StandInLink("inbound_b", initiator=False, status=RNS.Link.ACTIVE)
router.delivery_remote_identified(inbound_a, id_a)
router.delivery_remote_identified(inbound_b, id_b)
v["remote_identified"] = {
    "keys": sorted(k.hex() for k in router.backchannel_links),
    "link_for_hash_a": router.backchannel_links[hash_a].name,
    "available_hash_a": router.delivery_link_available(hash_a),
    "available_unknown": router.delivery_link_available(bytes(16)),
}
reset()
router.direct_links[hash_c] = StandInLink("direct_c", True, RNS.Link.ACTIVE)
v["available_direct_only"] = router.delivery_link_available(hash_c)

# DIRECT branch with a backchannel and no direct link (:2856-2879).
reset()
router.backchannel_links[hash_b] = StandInLink("backchannel", False, RNS.Link.ACTIVE)
m = message(LXMessage.DIRECT)
router.process_outbound()
v["direct_over_backchannel"] = {
    "sent_on": m.sent_on, "delivery_attempts": m.delivery_attempts,
    "progress": m.progress, "state": m.state,
    "direct_link_created": hash_b in router.direct_links, "links_constructed": len(created_links),
}

# Both maps hold a link: the direct link wins (:2858-2867).
reset()
router.direct_links[hash_b] = StandInLink("direct", True, RNS.Link.ACTIVE)
router.backchannel_links[hash_b] = StandInLink("backchannel", False, RNS.Link.ACTIVE)
m = message(LXMessage.DIRECT)
router.process_outbound()
v["direct_preferred"] = {"sent_on": m.sent_on}

# A pending backchannel is waited on (:2903-2905).
reset()
router.backchannel_links[hash_b] = StandInLink("backchannel", False, RNS.Link.PENDING)
m = message(LXMessage.DIRECT)
router.process_outbound()
v["pending_backchannel"] = {
    "sent_on": m.sent_on, "delivery_attempts": m.delivery_attempts,
    "still_held": hash_b in router.backchannel_links, "path_requests": len(path_requests),
}

# A closed backchannel is dropped (:2885-2902).
for label, activated in (("closed_after_activation", time.time() - 5), ("closed_never_activated", None)):
    reset()
    router.backchannel_links[hash_b] = StandInLink("backchannel", False, RNS.Link.CLOSED, activated)
    m = message(LXMessage.DIRECT)
    available_before = router.delivery_link_available(hash_b)
    before = time.time()
    router.process_outbound()
    v[label] = {
        "available_before": available_before,
        "available_after": router.delivery_link_available(hash_b),
        "in_backchannel_links": hash_b in router.backchannel_links,
        "in_direct_links": hash_b in router.direct_links,
        "path_requests": len(path_requests),
        "path_request_retried": getattr(m, "path_request_retried", False),
        "delivery_attempts": m.delivery_attempts,
        "rescheduled": m.next_delivery_attempt is not None and m.next_delivery_attempt > before,
        "sent_on": m.sent_on,
    }

# Backchannel identification on a delivered DIRECT message (:2770-2783).
reset()
direct = StandInLink("direct", initiator=True, status=RNS.Link.ACTIVE)
router.direct_links[hash_b] = direct
first = message(LXMessage.DIRECT, state=LXMessage.DELIVERED)
router.process_outbound()
after_first = list(direct.identified_as)
second = message(LXMessage.DIRECT, state=LXMessage.DELIVERED)
router.process_outbound()
v["identify_after_delivery"] = {
    "identified_as_after_first": after_first,
    "identified_as_after_second": direct.identified_as,
    "backchannel_identified": getattr(direct, "backchannel_identified", False),
    "configured": direct.configured,
    "pending_after": len(router.pending_outbound),
    "accept_app": RNS.Link.ACCEPT_APP,
}


reset()
direct = StandInLink("direct", initiator=True, status=RNS.Link.ACTIVE)
router.direct_links[hash_b] = direct
large = message(LXMessage.DIRECT, state=LXMessage.DELIVERED, content="x" * 2000)
router.process_outbound()
v["identify_after_resource_delivery"] = {
    "representation_is_resource": large.representation == LXMessage.RESOURCE,
    "identified_as": direct.identified_as,
}


def identify_case(link_initiator, method, source, with_direct_link=True):
    reset()
    link = StandInLink("direct", initiator=link_initiator, status=RNS.Link.ACTIVE)
    if with_direct_link:
        router.direct_links[hash_b] = link
    else:
        router.backchannel_links[hash_b] = link
    message(method, source=source, state=LXMessage.DELIVERED)
    router.process_outbound()
    return {"identified_as": link.identified_as,
            "backchannel_identified": getattr(link, "backchannel_identified", False),
            "configured": link.configured}


v["identify_not_initiator"] = identify_case(False, LXMessage.DIRECT, dest_a)
v["identify_source_not_registered"] = identify_case(True, LXMessage.DIRECT, src_c)
v["identify_opportunistic"] = identify_case(True, LXMessage.OPPORTUNISTIC, dest_a)
v["identify_over_backchannel"] = identify_case(False, LXMessage.DIRECT, dest_a, with_direct_link=False)

print(json.dumps(v, indent=1, sort_keys=True))
os._exit(0)
