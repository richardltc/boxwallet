package models

import "time"

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

type NEXAListTransactions struct {
	Result []struct {
		InvolvesWatchonly int           `json:"involvesWatchonly"`
		Address           string        `json:"address"`
		Amount            float64       `json:"amount"`
		Vout              int           `json:"vout"`
		Category          string        `json:"category"`
		Account           string        `json:"account"`
		Confirmations     int           `json:"confirmations"`
		Bcconfirmations   int           `json:"bcconfirmations"`
		Generated         bool          `json:"generated"`
		Txid              string        `json:"txid"`
		Walletconflicts   []interface{} `json:"walletconflicts"`
		Time              int           `json:"time"`
		Timereceived      int           `json:"timereceived"`
		Blockhash         string        `json:"blockhash,omitempty"`
		Blockindex        int           `json:"blockindex,omitempty"`
		Blocktime         int           `json:"blocktime,omitempty"`
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

type NEXATicker struct {
	NEXA struct {
		ID                            int         `json:"id"`
		Name                          string      `json:"name"`
		Symbol                        string      `json:"symbol"`
		Slug                          string      `json:"slug"`
		NumMarketPairs                int         `json:"num_market_pairs"`
		DateAdded                     time.Time   `json:"date_added"`
		Tags                          []string    `json:"tags"`
		MaxSupply                     interface{} `json:"max_supply"`
		CirculatingSupply             int64       `json:"circulating_supply"`
		TotalSupply                   int64       `json:"total_supply"`
		IsActive                      int         `json:"is_active"`
		InfiniteSupply                bool        `json:"infinite_supply"`
		Platform                      interface{} `json:"platform"`
		CmcRank                       int         `json:"cmc_rank"`
		IsFiat                        int         `json:"is_fiat"`
		SelfReportedCirculatingSupply int64       `json:"self_reported_circulating_supply"`
		SelfReportedMarketCap         float64     `json:"self_reported_market_cap"`
		TvlRatio                      interface{} `json:"tvl_ratio"`
		LastUpdated                   time.Time   `json:"last_updated"`
		Quote                         struct {
			BTC struct {
				Price                 float64     `json:"price"`
				Volume24H             float64     `json:"volume_24h"`
				VolumeChange24H       float64     `json:"volume_change_24h"`
				PercentChange1H       float64     `json:"percent_change_1h"`
				PercentChange24H      float64     `json:"percent_change_24h"`
				PercentChange7D       float64     `json:"percent_change_7d"`
				PercentChange30D      float64     `json:"percent_change_30d"`
				PercentChange60D      float64     `json:"percent_change_60d"`
				PercentChange90D      float64     `json:"percent_change_90d"`
				MarketCap             float64     `json:"market_cap"`
				MarketCapDominance    int         `json:"market_cap_dominance"`
				FullyDilutedMarketCap float64     `json:"fully_diluted_market_cap"`
				Tvl                   interface{} `json:"tvl"`
				LastUpdated           time.Time   `json:"last_updated"`
			} `json:"BTC"`
			USD struct {
				Price                 float64     `json:"price"`
				Volume24H             float64     `json:"volume_24h"`
				VolumeChange24H       float64     `json:"volume_change_24h"`
				PercentChange1H       float64     `json:"percent_change_1h"`
				PercentChange24H      float64     `json:"percent_change_24h"`
				PercentChange7D       float64     `json:"percent_change_7d"`
				PercentChange30D      float64     `json:"percent_change_30d"`
				PercentChange60D      float64     `json:"percent_change_60d"`
				PercentChange90D      float64     `json:"percent_change_90d"`
				MarketCap             float64     `json:"market_cap"`
				MarketCapDominance    int         `json:"market_cap_dominance"`
				FullyDilutedMarketCap float64     `json:"fully_diluted_market_cap"`
				Tvl                   interface{} `json:"tvl"`
				LastUpdated           time.Time   `json:"last_updated"`
			} `json:"USD"`
		} `json:"quote"`
	} `json:"NEXA"`
}
