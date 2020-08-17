package op

import (
	"crypto/rand"
	"fmt"
	"log"
	// dot import so go code would resemble as much as native SQL
	// dot import is not mandatory
	//. "richardmace.co.uk/rnserver/gen/rocknet/rocknet/table"
	//. "github.com/go-jet/jet/postgres"
)

type WalletModel struct {
}

// This will get the default wallet address
func createGUID() (string, error) {
	b := make([]byte, 16)
	_, err := rand.Read(b)
	if err != nil {
		log.Fatal(err)
	}
	uuid := fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])

	return uuid, err
}
