package bend

const (
	CCoinNameBitcoinPlus   string = "BitcoinPlus"
	CCoinAbbrevBitcoinPlus string = "XBC"

	CBitcoinPlusCoreVersion string = "2.8.2"
	//CDFBitcoinPlusFileArm32          = "bitcoinplus-" + CBitcoinPlusCoreVersion + "-arm-linux-gnueabihf.tar.gz"
	//CDFBitcoinPlusFileArm64          = "bitcoinplus-" + CBitcoinPlusCoreVersion + "-aarch64-linux-gnu.tar.gz"
	CDFBitcoinPlusFileLinux32 = "bitcoinplus-" + CBitcoinPlusCoreVersion + "-linux32.tar.gz"
	CDFBitcoinPlusFileLinux64 = "bitcoinplus-" + CBitcoinPlusCoreVersion + "-linux64.tar.gz"
	//CDFBitcoinPlusFilemacOS          = "bitcoinplus-" + CBitcoinPlusCoreVersion + "-osx64.tar.gz"
	//CDFBitcoinPlusFileWindows        = "bitcoinplus-" + CBitcoinPlusCoreVersion + "-win64.zip"

	// Directory const
	CBitcoinPlusExtractedDirArm     string = "bitcoinplus-" + CBitcoinPlusCoreVersion + "/"
	CBitcoinPlusExtractedDirLinux   string = "bitcoinplus-" + CBitcoinPlusCoreVersion + "/"
	CBitcoinPlusExtractedDirWindows string = "bitcoinplus-" + CBitcoinPlusCoreVersion + "\\"

	CDownloadURLBitcoinPlus string = "https://github.com/bitcoinplusorg/xbcwalletsource/releases/download/v" + CBitcoinPlusCoreVersion + "/"

	// BitcoinPlus Wallet Constants
	cBitcoinPlusHomeDir    string = ".bitcoinplus"
	cBitcoinPlusHomeDirWin string = "bitcoinplus"

	// File constants
	cBitcoinPlusConfFile   string = "bitcoinplus.conf"
	CBitcoinPlusCliFile    string = "bitcoinplus-cli"
	CBitcoinPlusCliFileWin string = "bitcoinplus-cli.exe"
	CBitcoinPlusDFile      string = "bitcoinplusd"
	CBitcoinPlusDFileWin   string = "bitcoinplusd.exe"
	CBitcoinPlusTxFile     string = "bitcoinplus-tx"
	CBitcoinPlusTxFileWin  string = "bitcoinplus-tx.exe"

	// pivx.conf file constants
	CBitcoinPlusRPCUser string = "bitcoinplusrpc"
	CBitcoinPlusRPCPort string = "8885"
)
