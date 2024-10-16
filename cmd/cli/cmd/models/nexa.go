package models

type NEXABlockchainInfo struct {
	Result struct {
		Chain                string        `json:"chain"`
		Blocks               int           `json:"blocks"`
		Headers              int           `json:"headers"`
		Bestblockhash        string        `json:"bestblockhash"`
		Difficulty           float64       `json:"difficulty"`
		Mediantime           int           `json:"mediantime"`
		Forktime             string        `json:"forktime"`
		Forkactive           string        `json:"forkactive"`
		Forkactivenextblock  string        `json:"forkactivenextblock"`
		Verificationprogress float64       `json:"verificationprogress"` // was int
		Initialblockdownload bool          `json:"initialblockdownload"`
		Chainwork            string        `json:"chainwork"`
		Coinsupply           int64         `json:"coinsupply"`
		SizeOnDisk           int           `json:"size_on_disk"`
		Pruned               bool          `json:"pruned"`
		Softforks            []interface{} `json:"softforks"`
		Bip9Softforks        struct {
		} `json:"bip9_softforks"`
		Bip135Forks struct {
		} `json:"bip135_forks"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type NEXAInfo struct {
	Result struct {
		Version         int     `json:"version"`
		Protocolversion int     `json:"protocolversion"`
		Walletversion   int     `json:"walletversion"`
		Balance         float64 `json:"balance"`
		Blocks          int     `json:"blocks"`
		Headers         int     `json:"headers"`
		Timeoffset      int     `json:"timeoffset"`
		Connections     int     `json:"connections"`
		PeersGraphene   int     `json:"peers_graphene"`
		PeersXthinblock int     `json:"peers_xthinblock"`
		PeersCmpctblock int     `json:"peers_cmpctblock"`
		Proxy           string  `json:"proxy"`
		Difficulty      float64 `json:"difficulty"`
		Testnet         bool    `json:"testnet"`
		Keypoololdest   int     `json:"keypoololdest"`
		Keypoolsize     int     `json:"keypoolsize"`
		Paytxfee        int     `json:"paytxfee"`
		Relayfee        int     `json:"relayfee"`
		Status          string  `json:"status"`
		Txindex         string  `json:"txindex"`
		Tokendesc       string  `json:"tokendesc"`
		Tokenmint       string  `json:"tokenmint"`
		Errors          string  `json:"errors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type NEXANetworkInfo struct {
	Result struct {
		Version            int      `json:"version"`
		Subversion         string   `json:"subversion"`
		Protocolversion    int      `json:"protocolversion"`
		Localservices      string   `json:"localservices"`
		Localservicesnames []string `json:"localservicesnames"`
		Timeoffset         int      `json:"timeoffset"`
		Connections        int      `json:"connections"`
		Networks           []struct {
			Name                      string `json:"name"`
			Limited                   bool   `json:"limited"`
			Reachable                 bool   `json:"reachable"`
			Proxy                     string `json:"proxy"`
			ProxyRandomizeCredentials bool   `json:"proxy_randomize_credentials"`
		} `json:"networks"`
		Relayfee         int           `json:"relayfee"`
		Limitfreerelay   string        `json:"limitfreerelay"`
		Maxallowednetmsg int           `json:"maxallowednetmsg"`
		Localaddresses   []interface{} `json:"localaddresses"`
		Thinblockstats   struct {
			Enabled              bool   `json:"enabled"`
			Summary              string `json:"summary"`
			InboundPercent       string `json:"inbound_percent"`
			OutboundPercent      string `json:"outbound_percent"`
			ResponseTime         string `json:"response_time"`
			ValidationTime       string `json:"validation_time"`
			OutboundBloomFilters string `json:"outbound_bloom_filters"`
			InboundBloomFilters  string `json:"inbound_bloom_filters"`
			ThinBlockSize        string `json:"thin_block_size"`
			ThinFullTx           string `json:"thin_full_tx"`
			Rerequested          string `json:"rerequested"`
		} `json:"thinblockstats"`
		Compactblockstats struct {
			Enabled          bool   `json:"enabled"`
			Summary          string `json:"summary"`
			InboundPercent   string `json:"inbound_percent"`
			OutboundPercent  string `json:"outbound_percent"`
			ResponseTime     string `json:"response_time"`
			ValidationTime   string `json:"validation_time"`
			CompactBlockSize string `json:"compact_block_size"`
			CompactFullTx    string `json:"compact_full_tx"`
			Rerequested      string `json:"rerequested"`
		} `json:"compactblockstats"`
		Grapheneblockstats struct {
			Enabled                  bool   `json:"enabled"`
			Summary                  string `json:"summary"`
			InboundPercent           string `json:"inbound_percent"`
			OutboundPercent          string `json:"outbound_percent"`
			ResponseTime             string `json:"response_time"`
			ValidationTime           string `json:"validation_time"`
			Filter                   string `json:"filter"`
			Iblt                     string `json:"iblt"`
			Rank                     string `json:"rank"`
			GrapheneBlockSize        string `json:"graphene_block_size"`
			GrapheneAdditionalTxSize string `json:"graphene_additional_tx_size"`
			Rerequested              string `json:"rerequested"`
		} `json:"grapheneblockstats"`
		Warnings string `json:"warnings"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type NEXAWalletInfo struct {
	Result struct {
		Walletversion               int     `json:"walletversion"`
		Syncblock                   string  `json:"syncblock"`
		Syncheight                  int     `json:"syncheight"`
		Balance                     float64 `json:"balance"`
		UnconfirmedBalance          float64 `json:"unconfirmed_balance"`
		ImmatureBalance             float64 `json:"immature_balance"`
		WatchonlyBalance            float64 `json:"watchonly_balance"`
		UnconfirmedWatchonlyBalance float64 `json:"unconfirmed_watchonly_balance"`
		ImmatureWatchonlyBalance    float64 `json:"immature_watchonly_balance"`
		Txcount                     int     `json:"txcount"`
		Unspentcount                int     `json:"unspentcount"`
		Keypoololdest               int     `json:"keypoololdest"`
		Keypoolsize                 int     `json:"keypoolsize"`
		Paytxfee                    int     `json:"paytxfee"`
		UnlockedUntil               int     `json:"unlocked_until"`
		Hdmasterkeyid               string  `json:"hdmasterkeyid"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}
