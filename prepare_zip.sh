isbeta=$(git describe --abbrev=0 --tags | grep beta)
if [[ "$isbeta" != "" ]] 
then 
    xcodebuild -project V2RayXS.xcodeproj -target V2RayXS -configuration Debug -s
    cd build/Debug/
else
    cd build/Release/
fi
zip -r V2RayXS.app.zip V2RayXS.app
cd -