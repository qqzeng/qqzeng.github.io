hexo generate
cp -R public/* .deploy/qqzeng.github.io
cd .deploy/qqzeng.github.io
git add .
git commit -m “update”
git push origin master