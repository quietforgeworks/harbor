package outbound

import "testing"

func TestHarborEasyTierFailsClosed(t *testing.T) {
	p, err := NewEasyTier(EasyTierOption{})
	if p != nil || err == nil {
		t.Fatal("disabled EasyTier must return no proxy and an error")
	}
}
