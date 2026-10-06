#!/usr/bin/env python3
"""The Cimian consumer, run against the shared enrollment code in intune-gitops.

`shared/` and the `intune` consumer live in intune-gitops, so put both
enrollment directories on PYTHONPATH, this repo's first:

    PYTHONPATH="enrollment:../intune-gitops/enrollment" python3 -m unittest discover -s enrollment/tests -v
"""
from __future__ import annotations

import os
import unittest
from unittest import mock

import consumers.cimian as cimian
from consumers import registry

HEADER = ",".join(cimian.EXPECTED_HEADER)
ROW = "SAMPLEWIN001,Staff,IT,B1101,A001,Assigned,Active,Allocated,alex,Windows,Desktop,STAFF-IT-001"


class Publish(unittest.TestCase):
    def test_well_formed_projection_plans(self):
        self.assertEqual(cimian.converge(f"{HEADER}\n{ROW}\n", what_if=True), 0)

    def test_wrong_header_is_refused(self):
        self.assertEqual(cimian.converge(f"serial,catalog\n{ROW}\n", what_if=True), 1)

    def test_empty_projection_is_refused(self):
        self.assertEqual(cimian.converge(f"{HEADER}\n", what_if=True), 1)

    def test_floor_is_enforced(self):
        with mock.patch.object(cimian, "MIN_ROWS", 5):
            self.assertEqual(cimian.converge(f"{HEADER}\n{ROW}\n", what_if=True), 1)


class Registry(unittest.TestCase):
    def test_cimian_registers_beside_the_shared_intune_consumer(self):
        found = registry.load("cimian=consumers.cimian:converge")
        self.assertEqual(sorted(found), ["cimian", "intune"])
        self.assertIs(found["cimian"], cimian.converge)


if __name__ == "__main__":
    unittest.main(verbosity=2)
