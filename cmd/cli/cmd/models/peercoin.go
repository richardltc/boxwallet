package models

import "time"

type PPCBlockchainInfo struct {
	Result struct {
		Chain                string        `json:"chain"`
		Blocks               int           `json:"blocks"`
		Headers              int           `json:"headers"`
		Bestblockhash        string        `json:"bestblockhash"`
		Difficulty           float64       `json:"difficulty"`
		Mediantime           int           `json:"mediantime"`
		Verificationprogress float64       `json:"verificationprogress"`
		Initialblockdownload bool          `json:"initialblockdownload"`
		Chainwork            string        `json:"chainwork"`
		SizeOnDisk           int           `json:"size_on_disk"`
		Softforks            []interface{} `json:"softforks"`
		Warnings             string        `json:"warnings"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}
type PPCListReceivedByAddress struct {
	Result []struct {
		Address         string   `json:"address"`
		Account         string   `json:"account"`
		Amount          float64  `json:"amount"`
		Confirmations   int      `json:"confirmations"`
		Bcconfirmations int      `json:"bcconfirmations"`
		Txids           []string `json:"txids"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type PPCListTransactions struct {
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

type PPCNetworkInfo struct {
	Result struct {
		Version         int    `json:"version"`
		Subversion      string `json:"subversion"`
		Protocolversion int    `json:"protocolversion"`
		Localservices   string `json:"localservices"`
		Localrelay      bool   `json:"localrelay"`
		Timeoffset      int    `json:"timeoffset"`
		Networkactive   bool   `json:"networkactive"`
		Connections     int    `json:"connections"`
		Networks        []struct {
			Name                      string `json:"name"`
			Limited                   bool   `json:"limited"`
			Reachable                 bool   `json:"reachable"`
			Proxy                     string `json:"proxy"`
			ProxyRandomizeCredentials bool   `json:"proxy_randomize_credentials"`
		} `json:"networks"`
		Localaddresses []interface{} `json:"localaddresses"`
		Warnings       string        `json:"warnings"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type PPCNewAddress struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type PPCTicker struct {
	PPC struct {
		ID                int         `json:"id"`
		Name              string      `json:"name"`
		Symbol            string      `json:"symbol"`
		Slug              string      `json:"slug"`
		NumMarketPairs    int         `json:"num_market_pairs"`
		DateAdded         time.Time   `json:"date_added"`
		Tags              []string    `json:"tags"`
		MaxSupply         interface{} `json:"max_supply"`
		CirculatingSupply float64     `json:"circulating_supply"`
		TotalSupply       float64     `json:"total_supply"`
		IsActive          int         `json:"is_active"`
		Platform          interface{} `json:"platform"`
		CmcRank           int         `json:"cmc_rank"`
		IsFiat            int         `json:"is_fiat"`
		LastUpdated       time.Time   `json:"last_updated"`
		Quote             struct {
			BTC struct {
				Price            float64   `json:"price"`
				Volume24H        float64   `json:"volume_24h"`
				PercentChange1H  float64   `json:"percent_change_1h"`
				PercentChange24H float64   `json:"percent_change_24h"`
				PercentChange7D  float64   `json:"percent_change_7d"`
				PercentChange30D float64   `json:"percent_change_30d"`
				PercentChange60D float64   `json:"percent_change_60d"`
				PercentChange90D float64   `json:"percent_change_90d"`
				MarketCap        float64   `json:"market_cap"`
				LastUpdated      time.Time `json:"last_updated"`
			} `json:"BTC"`
			USD struct {
				Price            float64   `json:"price"`
				Volume24H        float64   `json:"volume_24h"`
				PercentChange1H  float64   `json:"percent_change_1h"`
				PercentChange24H float64   `json:"percent_change_24h"`
				PercentChange7D  float64   `json:"percent_change_7d"`
				PercentChange30D float64   `json:"percent_change_30d"`
				PercentChange60D float64   `json:"percent_change_60d"`
				PercentChange90D float64   `json:"percent_change_90d"`
				MarketCap        float64   `json:"market_cap"`
				LastUpdated      time.Time `json:"last_updated"`
			} `json:"USD"`
		} `json:"quote"`
	} `json:"PPC"`
}

type PPCWalletInfo struct {
	Result struct {
		Walletname            string  `json:"walletname"`
		Walletversion         int     `json:"walletversion"`
		Balance               float64 `json:"balance"`
		UnconfirmedBalance    float64 `json:"unconfirmed_balance"`
		ImmatureBalance       float64 `json:"immature_balance"`
		Txcount               int     `json:"txcount"`
		Keypoololdest         int     `json:"keypoololdest"`
		Keypoolsize           int     `json:"keypoolsize"`
		KeypoolsizeHdInternal int     `json:"keypoolsize_hd_internal"`
		UnlockedUntil         int     `json:"unlocked_until"`
		Hdmasterkeyid         string  `json:"hdmasterkeyid"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type PPCWalletUnlockFS struct {
	Result struct {
		UnlockedMintingOnly bool `json:"unlocked_minting_only"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}
