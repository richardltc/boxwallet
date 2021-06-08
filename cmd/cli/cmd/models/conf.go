package models

type Conf struct {
	workingDir            string
	BlockchainSynced      bool        // If no, don't ask to encrypt wallet within dash command
	Currency              string      // USD, GBP
	FirstTimeRun          bool        // Is this the first time the server has run? If so, we need to store the BinFolder
	PerformHealthCheck    bool        // Should we perform a health check
	LastHealthCheck       string      // When the last health check was run
	RunHealthCheckAt      string      // What time we need to perform a health check
	ProjectType           ProjectType // The project type
	Port                  string      // The port that the server should run on
	RefreshTimer          int         // Refresh interval
	RPCuser               string      // The rpcuser
	RPCpassword           string      // The rpc password
	ServerIP              string      // The IP address of the coin daemon server
	UserConfirmedWalletBU bool        // Whether or not the user has said they've stored their recovery seed has been stored
}
