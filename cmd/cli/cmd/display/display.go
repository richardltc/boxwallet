package display

import (
	"fmt"

	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
)

const (
	cStakeReceived   string = "\u2607" + "\u2607" + "\u2607"
	cPaymentReceived string = "<--"
	cPaymentSent     string = "-->"

	cProg1 string = "|"
	cProg2 string = "/"
	cProg3 string = "-"
	cProg4 string = "\\"
	cProg5 string = "|"
	cProg6 string = "/"
	cProg7 string = "-"
	cProg8 string = "\\"

	CUTFTickBold string = "\u2713"
)

type About interface {
	About(coinAuth *models.CoinAuth) string
}

type InitialBalance interface {
	InitialBalance() string
}

type InitialNetwork interface {
	InitialNetwork() string
}

type LiveNetwork interface {
	LiveNetwork() string
}

type LiveTransactions interface {
	LiveTransactions() (containsZeroConfs bool, rows [][]string)
}

type LiveWallet interface {
	LiveWallet() string
}

type DisplayBCSync interface {
	BlockchainSyncTxt() string
}

type RefreshDifficulty interface {
	RefreshDifficulty()
}

type RefreshNetwork interface {
	RefreshNetwork(coinAuth *models.CoinAuth)
}

type RefreshTransactions interface {
	RefreshTransactions(coinAuth *models.CoinAuth)
}

func ConvertBCVerification(verificationPG float64) string {
	var sProg string
	var fProg float64

	fProg = verificationPG * 100
	sProg = fmt.Sprintf("%.2f", fProg)
	if sProg == "100%" {
		sProg = "99.99%"
	}

	return sProg
}

func GetCategoryColour(s string) string {
	switch s {
	case "receive":
		return "green"
	case "send":
		return "red"
	case "stake", "stake_reward", "generate":
		return "green"
	}

	return "white"
}

func GetCategorySymbol(s string) string {
	switch s {
	case "receive":
		return cPaymentReceived
	case "send":
		return cPaymentSent
	case "stake", "stake_reward", "generate":
		return cStakeReceived
	}
	return s
}

func NextProgBCIndicator(previousIndicator string) string {
	if previousIndicator == cProg1 {
		return cProg2
	} else if previousIndicator == cProg2 {
		return cProg3
	} else if previousIndicator == cProg3 {
		return cProg4
	} else if previousIndicator == cProg4 {
		return cProg5
	} else if previousIndicator == cProg5 {
		return cProg6
	} else if previousIndicator == cProg6 {
		return cProg7
	} else if previousIndicator == cProg7 {
		return cProg8
	} else if previousIndicator == cProg8 || previousIndicator == "" {
		return cProg1
	} else {
		return cProg1
	}
}

func NextProgMNIndicator(previousIndicator string) string {
	if previousIndicator == cProg1 {
		return cProg2
	} else if previousIndicator == cProg2 {
		return cProg3
	} else if previousIndicator == cProg3 {
		return cProg4
	} else if previousIndicator == cProg4 {
		return cProg5
	} else if previousIndicator == cProg5 {
		return cProg6
	} else if previousIndicator == cProg6 {
		return cProg7
	} else if previousIndicator == cProg7 {
		return cProg8
	} else if previousIndicator == cProg8 || previousIndicator == "" {
		return cProg1
	} else {
		return cProg1
	}
}
