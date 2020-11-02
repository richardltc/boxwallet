package bend

const (
	CCoinNameScala string = "Scala"

	CScalaCoreVersion string = "0.15.0.1"
	//CDFScalaRPi       string = "Vertcoin-" + CScalaCoreVersion + "-rPI.zip"
	CDFScalaLinux   string = "scala-v" + CScalaCoreVersion + "-linux-amd64.zip"
	CDFScalaWindows string = "scala-v" + CScalaCoreVersion + "-win64.zip"

	CScalaExtractedDirLinux = "scala-v" + CScalaCoreVersion + "-linux-amd64/"

	CDownloadURLScala string = "https://github.com/scala-project/scala-core/releases/download/" + CScalaCoreVersion + "/"

	CScalaHomeDir    string = ".scala"
	CScalaHomeDirWin string = "SCALA"

	CScalaConfFile   string = "scala.conf"
	CScalaCliFile    string = "scala-cli"
	CScalaCliFileWin string = "scala-cli.exe"
	CScalaDFile      string = "scalad"
	CScalaDFileWin   string = "scalad.exe"
	CScalaTxFile     string = "scala-tx"
	CScalaTxFileWin  string = "scala-tx.exe"

	CScalaRPCPort string = "5888"
)
