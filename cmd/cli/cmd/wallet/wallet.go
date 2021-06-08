package wallet

import "richardmace.co.uk/boxwallet/cmd/cli/cmd/models"

type Wallet interface {
	DaemonRunning() (bool, error)
	WalletNeedsEncrypting(coinAuth *models.CoinAuth) (bool, error)
	WalletLoadingStatus(coinAuth *models.CoinAuth) models.WLSType
	WalletResync() error
}

type WalletSecurityState interface {
	WalletSecurityState(coinAuth *models.CoinAuth) (models.WEType, error)
}
