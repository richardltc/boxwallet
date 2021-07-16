package currencyconvert

import (
	"encoding/json"
	"errors"
	"io/ioutil"
	"net/http"
	"strings"
)

var pricePerCoinAUD usd2AUDRespStruct
var pricePerCoinGBP usd2GBPRespStruct

type CurrencyConvert struct {
	coin string
}

type usd2AUDRespStruct struct {
	Rates struct {
		AUD float64 `json:"AUD"`
	} `json:"rates"`
	Base string `json:"base"`
	Date string `json:"date"`
}

type usd2GBPRespStruct struct {
	Rates struct {
		GBP float64 `json:"GBP"`
	} `json:"rates"`
	Base string `json:"base"`
	Date string `json:"date"`
}

func (c *CurrencyConvert) Bootstrap(coin string) {
	c.coin = strings.ToUpper(coin)
}

func (c *CurrencyConvert) Convert(usd float64) float64 {
	var converted float64

	switch c.coin {
	case "AUD":
		converted = usd * pricePerCoinAUD.Rates.AUD
	case "GBP":
		converted = usd * pricePerCoinGBP.Rates.GBP
	}

	return converted
}

func (c *CurrencyConvert) Refresh() {
	switch c.coin {
	case "AUD":
		_ = updateAUDPriceInfo()
	case "GBP":
		_ = updateGBPPriceInfo()
	}
}

func updateAUDPriceInfo() error {
	resp, err := http.Get("https://api.exchangeratesapi.io/latest?base=USD&symbols=AUD")
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	err = json.Unmarshal(body, &pricePerCoinAUD)
	if err != nil {
		return err
	}

	return errors.New("unable to updateAUDPriceInfo")
}

func updateGBPPriceInfo() error {
	resp, err := http.Get("https://api.exchangeratesapi.io/latest?base=USD&symbols=GBP")
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	err = json.Unmarshal(body, &pricePerCoinGBP)
	if err != nil {
		return err
	}
	return errors.New("unable to updateGBPPriceInfo")
}
