package bend

const (
	CCoinNameScala string = "Scala"

	CScalaCoreVersion string = "4.1.0"
	CDFScalaRPi       string = "Vertcoin-" + CScalaCoreVersion + "-rPI.zip"
	CDFScalaLinux     string = "linux-x64-" + CScalaCoreVersion + ".zip"
	CDFScalaWindows   string = "windows-x64-v" + CScalaCoreVersion + ".zip"

	//CScalaExtractedDirLinux = "linux-x64-" + CScalaCoreVersion + "/"
	CScalaExtractedDirLinux = "bin/"

	CDownloadURLScala string = "https://github.com/scala-network/Scala/releases/download/v" + CScalaCoreVersion + "/"

	CScalaHomeDir    string = ".scala"
	CScalaHomeDirWin string = "SCALA"

	CScalaConfFile   string = "scala.conf"
	CScalaCliFile    string = "scala-wallet-cli"
	CScalaCliFileWin string = "scala-wallet-cli.exe"
	CScalaDFile      string = "scalad"
	CScalaDFileWin   string = "scalad.exe"
	CScalaTxFile     string = "scala-wallet-rpc"
	CScalaTxFileWin  string = "scala-wallet-rpc.exe"

	CScalaRPCPort string = "11812"
)
