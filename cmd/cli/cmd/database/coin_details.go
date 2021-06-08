package database

import (
	"encoding/json"
	"errors"
	"io/ioutil"
	"os"
	"runtime"

	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
)

const (
	cCoinsFile string = "coins.json"
	cUnknown   string = "Unknown"
)

type CoinDetails struct {
	workingDir string
}

func (c *CoinDetails) Bootstrap(workingDir string) {
	c.workingDir = addTrailingSlash(workingDir)
}

func (c *CoinDetails) AddCoin(cd models.CoinDetails) error {
	allcoins, err := c.getCoins()
	if err != nil {
		return err
	}

	// Now make sure that we don't already have the coin.
	bExists := false
	for _, coin := range allcoins {
		if cd.CoinType == coin.CoinType {
			bExists = true
		}
	}

	if bExists {
		return nil
	}

	allcoins = append(allcoins, cd)

	jssb, err := json.MarshalIndent(allcoins, "", "  ")
	if err != nil {
		return err
	}

	f, err := os.Create(c.workingDir + cCoinsFile)
	if err != nil {
		return err
	}

	_, err = f.WriteString(string(jssb))
	err = f.Close()
	if err != nil {
		return err
	}
	return nil
}

func (c *CoinDetails) createDefaultCoinsDBFile() error {
	var allcoins []models.CoinDetails
	var coin1 = newCoinDetails()
	var coin2 = newCoinDetails()
	allcoins = append(allcoins, coin1)

	allcoins = append(allcoins, coin2)

	jssb, err := json.MarshalIndent(allcoins, "", "  ")
	if err != nil {
		return err
	}

	f, err := os.Create(c.workingDir + cCoinsFile)
	if err != nil {
		return err
	}

	_, err = f.WriteString(string(jssb))
	err = f.Close()
	if err != nil {
		return err
	}
	return nil
}

func (c *CoinDetails) getCoins() ([]models.CoinDetails, error) {
	var coinsd []models.CoinDetails

	if !fileExists(c.workingDir + cCoinsFile) {
		return coinsd, nil
	}
	file, err := ioutil.ReadFile(c.workingDir + cCoinsFile)
	if err != nil {
		return coinsd, err
	}

	err = json.Unmarshal([]byte(file), &coinsd)
	if err != nil {
		return coinsd, err
	}

	// Now, let's write the file back because it may have some new fields
	if err := c.setCoins(coinsd); err != nil {
		return nil, errors.New("unable to write coinsdb:" + err.Error())
	}

	return coinsd, nil
}

func newCoinDetails() models.CoinDetails {
	var coind models.CoinDetails
	coind.CoinName = "DIVI"
	coind.CoinType = 0
	coind.Monitor = false

	return coind
}

func (c *CoinDetails) setCoins(dbd []models.CoinDetails) error {
	jssb, _ := json.MarshalIndent(dbd, "", "  ")
	sFile := c.workingDir + cCoinsFile

	f, err := os.Create(sFile)
	if err != nil {
		return err
	}

	_, err = f.WriteString(string(jssb))
	err = f.Close()
	if err != nil {
		return err
	}
	return nil
}

func addTrailingSlash(filePath string) string {
	var lastChar = filePath[len(filePath)-1:]
	if runtime.GOOS == "windows" {
		if lastChar == "\\" {
			return filePath
		} else {
			return filePath + "\\"
		}
	} else {
		if lastChar == "/" {
			return filePath
		} else {
			return filePath + "/"
		}
	}
	//return ""
}

func fileExists(filename string) bool {
	info, err := os.Stat(filename)
	if os.IsNotExist(err) {
		return false
	}
	return !info.IsDir()
}
