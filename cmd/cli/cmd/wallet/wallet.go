package wallet

import (
	"github.com/AlecAivazis/survey/v2"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
)

type Wallet interface {
	DaemonRunning() (bool, error)
	WalletNeedsEncrypting(coinAuth *models.CoinAuth) (bool, error)
	WalletLoadingStatus(coinAuth *models.CoinAuth) models.WLSType
	WalletResync(appFolder string) error
}

type WalletEncrypt interface {
	WalletEncrypt(coinAuth *models.CoinAuth, pw string) (be.GenericRespStruct, error)
}

type WalletUnlockFS interface {
	WalletUnlockFS(coinAuth *models.CoinAuth, password string) error
}

type WalletSecurityState interface {
	WalletSecurityState(coinAuth *models.CoinAuth) (models.WEType, error)
}

func GetWalletEncryptionPassword() string {
	pw := ""
	prompt := &survey.Password{
		Message: "Please enter your wallet password",
	}
	survey.AskOne(prompt, &pw)

	return pw
}
