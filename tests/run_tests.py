#!/usr/bin/env python3
"""Convenience runner: python3 tests/run_tests.py  (equals unittest discover)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_sessium import (
    Batch3Tests,
    Batch4Tests,
    Batch5Tests,
    Batch6Tests,
    CommandTests,
    Phase3Tests,
    SyncTests,
    UnitTests,
)

if __name__ == "__main__":
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    suite.addTests(loader.loadTestsFromTestCase(UnitTests))
    suite.addTests(loader.loadTestsFromTestCase(CommandTests))
    suite.addTests(loader.loadTestsFromTestCase(SyncTests))
    suite.addTests(loader.loadTestsFromTestCase(Phase3Tests))
    suite.addTests(loader.loadTestsFromTestCase(Batch3Tests))
    suite.addTests(loader.loadTestsFromTestCase(Batch4Tests))
    suite.addTests(loader.loadTestsFromTestCase(Batch5Tests))
    suite.addTests(loader.loadTestsFromTestCase(Batch6Tests))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
