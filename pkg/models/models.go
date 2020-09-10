package models

import (
	"errors"
	//gwc "github.com/richardltc/gwcommon"
)

const (

	// Users
	CFldID             = "id"
	CFldCreated        = "created"
	CFldDefaultSiteId  = "default_siteid"
	CFldDeleted        = "deleted"
	CFldEmail          = "email"
	CFldHashedPassword = "hashed_password"
	CFldIsActive       = "is_active"
	CFldKnownAs        = "known_as"
	CFldLastUpdated    = "last_updated"
	CFldOwnerAddress   = "owner_address"
	CFldPassword       = "password"
	CFldUserName       = "user_name"
)

var (
	ErrNoRecord = errors.New("models: no matching record found")
	// Add a new ErrInvalidCredentials error. We'll use this later if a user
	// tries to login with an incorrect email address or password.
	ErrInvalidCredentials = errors.New("models: invalid credentials")
	// Add a new ErrDuplicateEmail error. We'll use this later if a user
	// tries to signup with an email address that's already in use.
	ErrDuplicateEmail = errors.New("models: duplicate email")
)

// PrivateKeyStruct - Get's returned from server to the client, when client requests priv key
type PrivateKeyStruct struct {
	Hdseed   string `json:"hdseed"`
	Mnemonic string `json:"mnemonic"`
	//ResponseCode gwc.ServerResponse
}

// ServerRequestStruct - Get's passed from client to the server, when making a server request
type ServerRequestStruct struct {
	ServerRequest string `json:"ServerRequest"`
}

// TokenResponseStruct - Get's passed from the server to the client, when responding to a GenereateToken request from client
type TokenResponseStruct struct {
	Desc  string `json: "Desc"` // Desc - e.g. Token successfully generated
	Token string `json: "Token"`
	//ResponseCode gwc.ServerResponse
}

type WalletStruct struct {
	PubAddress    string `json:"PublicAddress"`
	WalletAction  string `json:"WalletAction"`
	WalletRequest string `json:"WalletRequest"`
}

// WalletRequestStruct - Get's passed from client to the server, when making a wallet request
type WalletRequestStruct struct {
	Token         string `json:"Token"`
	WalletRequest string `json:"WalletRequest"`
}

type WalletStatusStruct struct {
	IsInstalled         bool `json: "IsInstalled"`
	IsWalletEncrypted   bool `json: "IsWalletEncrypted"`
	HasPrivKeyBeenSaved bool `json: "HasPrivKeyBeenSaved"`
	//ResponseCode        gwc.ServerResponse
}
