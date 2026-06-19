# NAS 操作约定

## 连接
- IP: 192.168.3.150 / 用户: sam.lu / 免密 SSH

## 文件上传（SCP 不可用！）
单文件：
```bash
cat /本地路径 | ssh sam.lu@192.168.3.150 "cat > /NAS路径"
```
目录：
```bash
cd /本地目录 && tar czf - . | ssh sam.lu@192.168.3.150 "cd /NAS目录 && tar xzf -"
```

## 部署路径
- /volume1/docker/ecs-expense/
