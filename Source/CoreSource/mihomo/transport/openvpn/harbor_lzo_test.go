package openvpn

import "testing"

func TestHarborRejectsLZOCompressed(t *testing.T) {
	for _, input := range [][]byte{{0x66}, {0x66, 1, 2, 3}, {}, {0x00, 1}} {
		out, err := lzo1xDecompressSafe(input)
		if err == nil || out != nil {
			t.Fatalf("unsupported input accepted: %x", input)
		}
	}
}

func TestHarborRetainsUncompressedLZOFrame(t *testing.T) {
	out, err := lzo1xDecompressSafe([]byte{0xfa, 1, 2, 3})
	if err != nil || len(out) != 3 || out[0] != 1 || out[2] != 3 {
		t.Fatal("uncompressed frame changed")
	}
}
