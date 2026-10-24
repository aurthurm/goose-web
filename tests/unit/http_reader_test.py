#!/usr/bin/env python3
"""TCP segmentation must not change the interpretation of HTTP responses."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "http_socket_checks", Path(__file__).resolve().parents[1] / "integration/http.py")
http = importlib.util.module_from_spec(spec)
spec.loader.exec_module(http)


class Socket:
    def __init__(self, chunks):
        self.chunks = iter(chunks)

    def recv(self, size):
        return next(self.chunks, b"")


class ResponseReaderTest(unittest.TestCase):
    def test_every_split_and_coalesced_pipeline(self):
        first = b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\na\x00b"
        second = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
        wire = first + second
        variants = [[wire], [bytes([byte]) for byte in wire]]
        variants += [[wire[:i], wire[i:]] for i in range(1, len(wire))]
        for chunks in variants:
            with self.subTest(chunks=chunks):
                reader = http.ResponseReader(Socket(chunks))
                self.assertEqual(reader.read()[2], b"a\x00b")
                self.assertEqual(reader.read()[2], b"ok")
                self.assertEqual(reader.buffer, b"")

    def test_head_and_304_have_no_body(self):
        wire = (b"HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\n"
                b"HTTP/1.1 304 Not Modified\r\nContent-Length: 99\r\n\r\n"
                b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
        reader = http.ResponseReader(Socket([wire]))
        self.assertEqual(reader.read(head=True)[2], b"")
        self.assertEqual(reader.read()[0], 304)
        self.assertEqual(reader.read()[0], 204)

    def test_truncated_response_fails(self):
        for wire in (b"HTTP/1.1 200 OK", b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\na"):
            with self.subTest(wire=wire), self.assertRaises(AssertionError):
                http.ResponseReader(Socket([wire])).read()


if __name__ == "__main__":
    unittest.main()
