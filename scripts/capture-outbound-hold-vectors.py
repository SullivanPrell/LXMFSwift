#!/usr/bin/env python3
"""Print the values that LXMF 1.2.1 computes for the outbound queue hold, as test vectors.

Tests/LXMFTests/OutboundHoldTests.swift transcribes the output. Run it with an interpreter that
has RNS, a scratch HOME, and an LXMF 1.2.1 source tree first on PYTHONPATH, so that the 1.2.1
sources load and not an older installed package:

    HOME=<scratch-home> PYTHONPATH=<lxmf-1.2.1-tree> python3 scripts/capture-outbound-hold-vectors.py

The script starts no RNS instance and opens no socket. It calls the router's methods
unbound, with a stand-in for self that supplies only what each method reads, and it replaces
the module's clock and random source. Time stands still at T0, and uniform(a, b) returns a
or b, so each jittered value prints as a minimum and a maximum.

The output has five sections. Transcribe each row into a test argument and keep the section
names in the test names, so a failing test names its source:

  1. schedule_attempt: the attempt limit, the next attempt's delay and the receipt timeout.
  2. slow_path: the threshold, the four-second cache and the 256-entry cap.
  3. slow_path_held: which queued messages wait, for seventeen queue layouts.
  4. outbound_concluded: a pass runs after the lock clears, and only for a slow-path message.
  5. __mark_delivered and __mark_propagated: idempotence, and the order of the two callbacks.

A header line names the LXMF file and version that produced the numbers. Check it before you
use the output: a venv copy of 1.1.1 has none of these methods.
"""
import importlib
import sys
import threading
import time as real_time
import types

import LXMF

router_module = importlib.import_module("LXMF.LXMRouter")
message_module = importlib.import_module("LXMF.LXMessage")
Router = router_module.LXMRouter
Message = message_module.LXMessage

T0 = 1000.0


class Clock:
    """The router module's `time`, frozen until a section moves it."""

    def __init__(self):
        self.now = T0
        self.sleep = real_time.sleep

    def time(self):
        return self.now


class Uniform:
    """The router module's `random`. Return the lower or the upper bound of the range."""

    def __init__(self):
        self.pick_upper = False

    def uniform(self, low, high):
        return high if self.pick_upper else low


clock = Clock()
uniform = Uniform()
router_module.time = clock
router_module.random = uniform


def fmt(value):
    if value is None:
        return "None"
    if isinstance(value, bool):
        return str(value)
    if isinstance(value, float):
        return f"{value:.6f}".rstrip("0").rstrip(".")
    return str(value)


def section(title):
    print()
    print(f"## {title}")


def header():
    for needed in ("slow_path", "slow_path_held", "outbound_concluded", "schedule_attempt"):
        if not hasattr(Router, needed):
            sys.exit(f"LXMF at {LXMF.__file__} has no {needed}: it is older than 1.2.1")
    print(f"# lxmf {LXMF.__version__} from {LXMF.__file__}")
    print(f"# DELIVERY_RETRY_WAIT={Router.DELIVERY_RETRY_WAIT} "
          f"MAX_DELIVERY_ATTEMPTS={Router.MAX_DELIVERY_ATTEMPTS} "
          f"PATH_REQUEST_WAIT={Router.PATH_REQUEST_WAIT} "
          f"PROCESSING_INTERVAL={Router.PROCESSING_INTERVAL} "
          f"AIRTIME_AWARE_MTU_TIME={Router.AIRTIME_AWARE_MTU_TIME} "
          f"DEFAULT_PER_HOP_TIMEOUT={router_module.RNS.Reticulum.DEFAULT_PER_HOP_TIMEOUT}")


def schedule_attempt_rows():
    section("schedule_attempt")
    print("# columns: path_request round_trip delivery_attempts -> max_delivery_attempts "
          "delay_min delay_max receipt_timeout awaiting_path")
    destination = b"\x01" * 16
    round_trips = [0, 6, 7, 7.2, 10, 11, 12, 13.5, 20, 40, 120]
    for path_request in (False, True):
        for round_trip in round_trips:
            for attempts in (0, 1, 3, 6):
                rows = []
                for upper in (False, True):
                    uniform.pick_upper = upper
                    stand_in = types.SimpleNamespace(
                        medium_path_timeout=lambda rt=round_trip: rt,
                        destination_round_trip=lambda _hash, rt=round_trip: rt,
                    )
                    message = types.SimpleNamespace(
                        delivery_attempts=attempts, max_delivery_attempts=None,
                        next_delivery_attempt=None, awaiting_path=False, receipt_timeout="unset",
                    )
                    Router.schedule_attempt(stand_in, message, destination, path_request)
                    rows.append(message)
                low, high = rows
                print(
                    f"{path_request!s:5} {fmt(round_trip):>5} {attempts} -> "
                    f"{high.max_delivery_attempts} {fmt(low.next_delivery_attempt - T0)} "
                    f"{fmt(high.next_delivery_attempt - T0)} {fmt(high.receipt_timeout)} "
                    f"{high.awaiting_path}"
                )
    uniform.pick_upper = False


def slow_path_rows():
    section("slow_path")
    round_trips = {}
    stand_in = types.SimpleNamespace(
        slow_path_cache={},
        destination_round_trip=lambda destination: round_trips[destination],
    )

    def ask(destination):
        return Router.slow_path(stand_in, destination)

    print("# threshold: round_trip -> slow (strictly greater than DELIVERY_RETRY_WAIT)")
    for round_trip in (0, 9.999, 10, 10.0001, 11, 120):
        stand_in.slow_path_cache.clear()
        round_trips[b"t"] = round_trip
        print(f"{fmt(round_trip):>8} -> {ask(b't')}")

    print("# cache: an entry stamped at T0 says slow because the round trip was 11 s. "
          "The round trip then falls to 5 s.")
    print("# offset after the stamp -> answer (the stamp wins while the offset is below "
          "PROCESSING_INTERVAL)")
    stand_in.slow_path_cache.clear()
    clock.now = T0
    round_trips[b"c"] = 11
    print(f"+0 (first ask, round trip 11) -> {ask(b'c')}")
    round_trips[b"c"] = 5
    for offset in (3.9, 4.0, 4.1):
        clock.now = T0 + offset
        # A recomputed answer re-stamps the entry, so restore the original stamp each time.
        stand_in.slow_path_cache[b"c"] = (True, T0)
        print(f"+{offset} -> {ask(b'c')}")
    clock.now = T0

    print("# cap: entries before the call -> entries after (the cache empties when it holds "
          "more than 256)")
    for before in (0, 255, 256, 257, 300):
        stand_in.slow_path_cache.clear()
        for index in range(before):
            stand_in.slow_path_cache[b"e" + index.to_bytes(4, "big")] = (False, T0)
        round_trips[b"new"] = 1
        ask(b"new")
        print(f"{before:>4} -> {len(stand_in.slow_path_cache)}")
    clock.now = T0


def held_rows():
    section("slow_path_held")
    print("# Each layout is a queue in order. Each row reads: name, state, method, target, "
          "sent_on_slow_path, then the held result for that message.")
    print("# 'slow' names the targets for which slow_path answers True. N is the outbound "
          "propagation node.")
    states = {
        "OUTBOUND": Message.OUTBOUND, "SENDING": Message.SENDING, "SENT": Message.SENT,
        "DELIVERED": Message.DELIVERED, "FAILED": Message.FAILED,
        "CANCELLED": Message.CANCELLED, "REJECTED": Message.REJECTED,
    }
    methods = {
        "OPP": Message.OPPORTUNISTIC, "DIRECT": Message.DIRECT, "PROP": Message.PROPAGATED,
    }
    node = b"N" * 16

    def build(spec, slow):
        queue = []
        for name, state, method, target, flag in spec:
            queue.append(types.SimpleNamespace(
                name=name, state=states[state], method=methods[method],
                destination_hash=target, sent_on_slow_path=flag,
            ))
        stand_in = types.SimpleNamespace(
            pending_outbound=queue, outbound_propagation_node=node,
            slow_path=lambda target: target in slow,
        )
        stand_in.outbound_target = lambda other: Router.outbound_target(stand_in, other)
        stand_in.slow_path_in_flight = lambda other: Router.slow_path_in_flight(stand_in, other)
        results = []
        for message in queue:
            target = node if message.method == Message.PROPAGATED else message.destination_hash
            results.append(Router.slow_path_held(stand_in, message, target))
        return queue, results

    a, b, c = b"A" * 16, b"B" * 16, b"C" * 16
    layouts = [
        ("two to one slow target", {a},
         [("m1", "OUTBOUND", "DIRECT", a, False), ("m2", "OUTBOUND", "DIRECT", a, False)]),
        ("in flight direct holds another target", {a, b},
         [("m1", "SENDING", "DIRECT", a, True), ("m2", "OUTBOUND", "DIRECT", b, False)]),
        ("in flight opportunistic is SENT", {a, b},
         [("m1", "SENT", "OPP", a, True), ("m2", "OUTBOUND", "OPP", b, False)]),
        ("SENT direct is not in flight", {a, b},
         [("m1", "SENT", "DIRECT", a, True), ("m2", "OUTBOUND", "DIRECT", b, False)]),
        ("SENDING opportunistic is not in flight", {a, b},
         [("m1", "SENDING", "OPP", a, True), ("m2", "OUTBOUND", "OPP", b, False)]),
        ("propagated and SENT is skipped", {a, node},
         [("m1", "SENT", "PROP", a, True), ("m2", "OUTBOUND", "DIRECT", a, False)]),
        ("terminal states are skipped", {a},
         [("m1", "DELIVERED", "DIRECT", a, True), ("m2", "FAILED", "DIRECT", a, True),
          ("m3", "CANCELLED", "DIRECT", a, True), ("m4", "REJECTED", "DIRECT", a, True),
          ("m5", "OUTBOUND", "DIRECT", a, False)]),
        ("fast target is never held", set(),
         [("m1", "SENDING", "DIRECT", a, True), ("m2", "OUTBOUND", "DIRECT", a, False)]),
        ("only the candidate's target counts", {b},
         [("m1", "SENDING", "DIRECT", a, True), ("m2", "OUTBOUND", "DIRECT", b, False)]),
        ("a candidate that is not OUTBOUND waits for nothing", {a},
         [("m1", "SENDING", "DIRECT", a, True), ("m2", "SENDING", "DIRECT", a, True)]),
        ("ahead with the same target holds without a flag", {a},
         [("m1", "SENT", "OPP", a, False), ("m2", "OUTBOUND", "OPP", a, False)]),
        ("later messages with the same target wait for the first", {a},
         [("m1", "OUTBOUND", "DIRECT", a, False), ("m2", "OUTBOUND", "DIRECT", a, False),
          ("m3", "OUTBOUND", "DIRECT", a, False)]),
        ("behind and in flight holds", {a},
         [("m1", "OUTBOUND", "DIRECT", a, False), ("m2", "SENDING", "DIRECT", b, True)]),
        ("propagated target is the node", {node},
         [("m1", "OUTBOUND", "PROP", a, False), ("m2", "OUTBOUND", "PROP", b, False)]),
        ("a propagated message holds a direct one to the node", {node},
         [("m1", "OUTBOUND", "PROP", a, False), ("m2", "OUTBOUND", "DIRECT", node, False)]),
        ("propagated and SENT holds nothing for the node", {node},
         [("m1", "SENT", "PROP", a, True), ("m2", "OUTBOUND", "PROP", b, False)]),
        ("in flight without the flag holds nothing", {a, b},
         [("m1", "SENDING", "DIRECT", a, False), ("m2", "OUTBOUND", "DIRECT", b, False)]),
    ]
    for title, slow, spec in layouts:
        queue, results = build(spec, slow)
        slow_names = ",".join(sorted(chr(t[0]) if t != node else "N" for t in slow)) or "-"
        print(f"- {title} (slow {slow_names})")
        for message, held in zip(queue, results):
            print(f"    {message.name} {spec[queue.index(message)][1]:9} "
                  f"{spec[queue.index(message)][2]:6} target={chr(message.destination_hash[0])} "
                  f"flag={message.sent_on_slow_path!s:5} -> held={held}")


def concluded_rows():
    section("outbound_concluded")
    calls = []
    called = threading.Event()

    def process_outbound():
        calls.append(real_time.monotonic())
        called.set()

    router = types.SimpleNamespace(
        outbound_processing_lock=threading.Lock(), process_outbound=process_outbound,
    )

    plain = types.SimpleNamespace()
    Router.outbound_concluded(router, plain)
    real_time.sleep(0.3)
    print(f"message without sent_on_slow_path: process_outbound calls={len(calls)}")

    quick = types.SimpleNamespace(sent_on_slow_path=False)
    Router.outbound_concluded(router, quick)
    real_time.sleep(0.3)
    print(f"sent_on_slow_path False: process_outbound calls={len(calls)}")

    slow = types.SimpleNamespace(sent_on_slow_path=True)
    router.outbound_processing_lock.acquire()
    started = real_time.monotonic()
    Router.outbound_concluded(router, slow)
    real_time.sleep(0.4)
    print(f"sent_on_slow_path True, lock held 0.4 s: calls while held={len(calls)}")
    router.outbound_processing_lock.release()
    called.wait(2)
    waited = (calls[0] - started) if calls else float("nan")
    print(f"after release: calls={len(calls)} ran no sooner than the release="
          f"{waited >= 0.4}")


def mark_rows():
    section("__mark_delivered and __mark_propagated")
    destination, source = b"D" * 16, b"S" * 16
    order = []

    def build():
        message = Message(None, None, "x", "", destination_hash=destination, source_hash=source)
        message.register_delivery_callback(lambda m: order.append("delivery_callback"))
        message.concluded_callback = lambda m: order.append("concluded_callback")
        return message

    for label, method, start, expect_name in (
        ("__mark_delivered", "_LXMessage__mark_delivered", Message.SENDING, "DELIVERED"),
        ("__mark_propagated", "_LXMessage__mark_propagated", Message.SENDING, "SENT"),
    ):
        order.clear()
        message = build()
        message.state = start
        message.progress = 0.5
        getattr(message, method)(None)
        print(f"{label} from SENDING: state={message.state} ({expect_name}={getattr(Message, expect_name)}) "
              f"progress={message.progress} callbacks={order}")
        order.clear()
        getattr(message, method)(None)
        print(f"{label} again: callbacks={order}")
        order.clear()
        message.state = Message.OUTBOUND
        getattr(message, method)(None)
        print(f"{label} from OUTBOUND: state={message.state} callbacks={order}")

    order.clear()
    message = build()
    message.state = Message.SENT
    message._LXMessage__mark_delivered(None)
    print(f"__mark_delivered from SENT: state={message.state} callbacks={order}")
    order.clear()
    message = build()
    message.state = Message.DELIVERED
    message._LXMessage__mark_propagated(None)
    print(f"__mark_propagated from DELIVERED: state={message.state} callbacks={order}")
    print(f"states: OUTBOUND={Message.OUTBOUND} SENDING={Message.SENDING} SENT={Message.SENT} "
          f"DELIVERED={Message.DELIVERED}")


def main():
    header()
    schedule_attempt_rows()
    slow_path_rows()
    held_rows()
    concluded_rows()
    mark_rows()


if __name__ == "__main__":
    main()
