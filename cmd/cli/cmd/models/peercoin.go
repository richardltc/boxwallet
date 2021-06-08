package models

type PPCWalletInfo struct {
	Result struct {
		Walletversion      int     `json:"walletversion"`
		Balance            float64 `json:"balance"`
		UnconfirmedBalance float64 `json:"unconfirmed_balance"`
		ImmatureBalance    float64 `json:"immature_balance"`
		Txcount            int     `json:"txcount"`
		Keypoololdest      int     `json:"keypoololdest"`
		Keypoolsize        int     `json:"keypoolsize"`
		Paytxfee           float64 `json:"paytxfee"`
		UnlockedUntil      int     `json:"unlocked_until"`
		Hdmasterkeyid      string  `json:"hdmasterkeyid"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}
