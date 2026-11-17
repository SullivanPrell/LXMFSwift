#!/usr/bin/env python3
"""Print LXMF 1.3.0 stamp and stamp-cost behavior as JSON for
Tests/LXMFTests/Fixtures/PythonStampCostVectors.swift.

Calls the reference's own functions and router methods. The config it writes has no interfaces
and no shared instance; run it with the network denied as well:

    sandbox-exec -p '(version 1)(allow default)(deny network*)' \
        python3 -I scripts/capture-stamp-cost-vectors.py <empty-config-dir>

Needs rns and lxmf installed. The fixture was captured with RNS 1.6.0 and LXMF 1.3.0.
"""
import json
import os
import sys
from importlib.metadata import version

import RNS
import RNS.vendor.umsgpack as msgpack
from RNS.Stamps import COST_FP, quantize_cost, stamp_valid, stamp_value, stamp_workblock

import LXMF.LXStamper as LXStamper
from LXMF import LXMRouter
from LXMF.LXMF import pn_announce_data_is_valid, pn_stamp_cost_from_app_data, stamp_cost_from_app_data

cfg = sys.argv[1]
os.makedirs(cfg, exist_ok=True)
with open(os.path.join(cfg, "config"), "w") as f:
    f.write("[reticulum]\n  enable_transport = False\n  share_instance = No\n"
            "  panic_on_interface_error = No\n[logging]\n  loglevel = 2\n[interfaces]\n")
RNS.Reticulum(configdir=cfg, loglevel=RNS.LOG_CRITICAL)

LXMRouter.PROCESSING_INTERVAL = 3600


def first_stamp(material, rounds, minimum):
    """The first full_hash(i) whose value over material's workblock reaches minimum."""
    workblock = stamp_workblock(material, expand_rounds=rounds)
    i = 0
    while True:
        stamp = RNS.Identity.full_hash(i.to_bytes(4, "big"))
        value = stamp_value(workblock, stamp)
        if value >= minimum:
            return workblock, stamp, value
        i += 1


def validity(stamp, workblock, value):
    step = 1 / COST_FP
    costs = [value - step, value, value + step, float(int(value)), float(int(value) + 1)]
    return [{"cost": c, "valid": stamp_valid(stamp, c, workblock)} for c in costs]


out = {"rns": version("rns"), "lxmf": version("lxmf")}

# Stamps over each LXMF workblock (LXStamper.py:16-18).
material = bytes(range(32))
stamps = []
for name, rounds in [("message", LXStamper.WORKBLOCK_EXPAND_ROUNDS),
                     ("propagation", LXStamper.WORKBLOCK_EXPAND_ROUNDS_PN),
                     ("peering", LXStamper.WORKBLOCK_EXPAND_ROUNDS_PEERING)]:
    workblock, stamp, value = first_stamp(material, rounds, 6)
    stamps.append({"workblock": name, "rounds": rounds, "stamp": stamp.hex(), "value": value,
                   "validity": validity(stamp, workblock, value)})
out["material"] = material.hex()
out["stamps"] = stamps

# validate_pn_stamp (LXStamper.py:31-43).
lxm_data = bytes(range(16)) + bytes(range(100, 200))
transient_id = RNS.Identity.full_hash(lxm_data)
workblock, stamp, value = first_stamp(transient_id, LXStamper.WORKBLOCK_EXPAND_ROUNDS_PN, 5)
step = 1 / COST_FP
pn = []
for cost in [value - step, value, value + step]:
    result = LXStamper.validate_pn_stamp(lxm_data + stamp, cost)
    pn.append({"cost": cost, "value": result[2]})
out["pn_stamp"] = {"lxm_data": lxm_data.hex(), "stamp": stamp.hex(), "results": pn}

# validate_peering_key (LXStamper.py:26-29).
peering_id = bytes(range(32, 64))
workblock, key, value = first_stamp(peering_id, LXStamper.WORKBLOCK_EXPAND_ROUNDS_PEERING, 6)
out["peering_key"] = {"peering_id": peering_id.hex(), "key": key.hex(),
                      "results": [{"cost": c, "valid": LXStamper.validate_peering_key(peering_id, key, c)}
                                  for c in [value - step, value, value + step]]}

# Message store value component (LXMRouter.py:2874-2877) and its reader (:656).
out["store_value_component"] = [{"value": v, "component": f"_{quantize_cost(v)}"}
                                for v in [1, 16, 16.5, 8.3, 13.00390625]]
out["store_value_read"] = [{"component": c, "value": quantize_cost(c)}
                           for c in ["16", "16.0", "16.5", "8.30078125", "8.3"]]

storage = os.path.join(cfg, "lxmf-storage")
router = LXMRouter(storagepath=storage)
identity = RNS.Identity.from_bytes(bytes(range(64)))
delivery = router.register_delivery_identity(identity, display_name="Alice")

# set_inbound_stamp_cost and the delivery announce (LXMRouter.py:444-463, :1163-1182).
announces = []
for cost in [None, 0, 0.5, 1, 1.0, 8, 8.5, 8.3, 99.9, 100, 255, -3]:
    router.set_inbound_stamp_cost(delivery.hash, None)
    accepted = router.set_inbound_stamp_cost(delivery.hash, cost)
    announces.append({"cost": cost, "accepted": accepted, "stored": delivery.stamp_cost,
                      "app_data": router.get_announce_app_data(delivery.hash).hex()})
out["delivery_announces"] = announces

# The propagation node announce (LXMRouter.py:387-401).
node_announces = []
for costs in [(16.0, 3.0, 18.0), (16.5, 2.25, 18.75), (13, 0, 26)]:
    (router.propagation_stamp_cost, router.propagation_stamp_cost_flexibility,
     router.peering_cost) = costs
    node_announces.append({"costs": list(costs), "app_data": router.get_propagation_node_app_data().hex()})
out["node_announces"] = node_announces

# Readers (LXMF.py:183-199, :229-272).
delivery_cases = [
    [b"A", 9, [0], 8.5], [b"A", 9, [0], 7], [b"A", 9, [0], None], [b"A", 9, [0], "x"],
    [b"A", 9, [0], True], [b"A", 9, [0]], [b"A", None, [0], None], [b"A", 9, [0], 8.5, "extra"],
]
out["delivery_cost_reads"] = [{"app_data": msgpack.packb(c).hex(),
                               "cost": stamp_cost_from_app_data(msgpack.packb(c))} for c in delivery_cases]

base = [False, 1700000000, True, 256, 10240, [16, 3, 18], {}]
node_cases = [
    base,
    base + [[16.5, 2.25, 18.75]],
    base[:5] + [[16.5, 3.0, 18.0]] + base[6:],
    base + [[16.5, 2.25, 18.75], "extra"],
    base + ["x"],
    base + [["a", 1, 2]],
    base + [[None, 1, 2]],
    base + [[16.5, 2.25]],
]
out["node_cost_reads"] = [{"app_data": msgpack.packb(c).hex(),
                           "valid": pn_announce_data_is_valid(msgpack.packb(c)),
                           "cost": pn_stamp_cost_from_app_data(msgpack.packb(c))} for c in node_cases]

print(json.dumps(out, indent=1))
sys.stdout.flush()
os._exit(0)
