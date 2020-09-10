package bend

const (
	cDiviAddNodeURL string = "https://api.diviproject.org/v1/addnode"
)

type LotteryDiviRespStruct struct {
	Lottery struct {
		AverageBlockTime float64 `json:"averageBlockTime"`
		CurrentBlock     int     `json:"currentBlock"`
		NextLotteryBlock int     `json:"nextLotteryBlock"`
		Countdown        struct {
			Milliseconds float64 `json:"milliseconds"`
			Humanized    string  `json:"humanized"`
		} `json:"countdown"`
	} `json:"lottery"`
	Stats string `json:"stats"`
}

type MNSyncStatusDiviRespStruct struct {
	Result struct {
		IsBlockchainSynced         bool `json:"IsBlockchainSynced"`
		LastMasternodeList         int  `json:"lastMasternodeList"`
		LastMasternodeWinner       int  `json:"lastMasternodeWinner"`
		LastFailure                int  `json:"lastFailure"`
		NCountFailures             int  `json:"nCountFailures"`
		SumMasternodeList          int  `json:"sumMasternodeList"`
		SumMasternodeWinner        int  `json:"sumMasternodeWinner"`
		CountMasternodeList        int  `json:"countMasternodeList"`
		CountMasternodeWinner      int  `json:"countMasternodeWinner"`
		RequestedMasternodeAssets  int  `json:"RequestedMasternodeAssets"`
		RequestedMasternodeAttempt int  `json:"RequestedMasternodeAttempt"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type StakingStatusDiviRespStruct struct {
	Result struct {
		Validtime       bool `json:"validtime"`
		Haveconnections bool `json:"haveconnections"`
		Walletunlocked  bool `json:"walletunlocked"`
		Mintablecoins   bool `json:"mintablecoins"`
		Enoughcoins     bool `json:"enoughcoins"`
		Mnsync          bool `json:"mnsync"`
		StakingStatus   bool `json:"staking status"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type WalletInfoDiviRespStruct struct {
	Result struct {
		Walletversion      int     `json:"walletversion"`
		Balance            float64 `json:"balance"`
		UnconfirmedBalance float64 `json:"unconfirmed_balance"`
		ImmatureBalance    float64 `json:"immature_balance"`
		Txcount            int     `json:"txcount"`
		Keypoololdest      int     `json:"keypoololdest"`
		Keypoolsize        int     `json:"keypoolsize"`
		EncryptionStatus   string  `json:"encryption_status"`
		Hdchainid          string  `json:"hdchainid"`
		Hdaccountcount     int     `json:"hdaccountcount"`
		Hdaccounts         []struct {
			Hdaccountindex     int `json:"hdaccountindex"`
			Hdexternalkeyindex int `json:"hdexternalkeyindex"`
			Hdinternalkeyindex int `json:"hdinternalkeyindex"`
		} `json:"hdaccounts"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}
