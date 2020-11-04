package cmd

import (
	"fmt"
	"github.com/AlecAivazis/survey/v2"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
)

func HandleWalletBUGRS(pw string) (confirmedBU bool, err error) {
	sYes := "Yes"
	sAlreadyBU := "Already backed-up"
	sLater := "Later"

	buNow := ""
	buNowPrompt := &survey.Select{
		Message: "You haven't confirmed that you've backed up your wallet, do it now?:",
		Options: []string{sYes, sAlreadyBU, sLater},
	}
	survey.AskOne(buNowPrompt, &buNow)

	switch buNow {
	case sYes:
	case sAlreadyBU:
		return true, nil
	case sLater:
		return false, nil
	default:
		return false, fmt.Errorf("unable to determine buNow choice")
	}

	cliConf, err := be.GetConfigStruct("", true)
	if err != nil {
		fmt.Errorf("unable to load config file: %v", err)
	}

	// First check to make sure the wallet is unlocked or unencrypted
	wet, err := be.GetWalletEncryptionStatus()
	if err != nil {
		return false, err
	}

	// If the wallet is locked, and the password is blank, return
	if wet == be.WETLocked && pw == "" {
		return false, fmt.Errorf("error: your wallet is locked and the password is blank")
	}

	// If the wallet is locked, and we have a password, let's unlock it.
	if wet == be.WETLocked {
		if err := be.UnlockWalletVTC(&cliConf, pw); err != nil {
			return false, fmt.Errorf("unable to unlock wallet: %v", err)
		}
	}

	buOption := ""
	prompt := &survey.Select{
		Message: "Please choose how you'd like to backup your wallet:",
		Options: []string{be.BUWDisplayHDSeed, be.BUWWalletDat},
	}
	survey.AskOne(prompt, &buOption)

	switch buOption {
	case be.BUWDisplayHDSeed:
		pk, err := getPrivateKeyNew(&cliConf)
		if err != nil {
			return false, fmt.Errorf("Unable to getPrivateKey(): failed with %s\n", err)
		}
		fmt.Printf("\n\nYour private seed recovery details are as follows:\n\nHdseed: " +
			pk.Result.Hdseed + "\n\nMnemonic phrase: " +
			pk.Result.Mnemonic + "\n\nPlease make sure you safely secure this information, and then re-run " + be.CAppFilename + " dash again.\n\n")
	case be.BUWWalletDat:
	default:
		return false, fmt.Errorf("unable to determine buOption choice")
	}
	return true, nil
}
