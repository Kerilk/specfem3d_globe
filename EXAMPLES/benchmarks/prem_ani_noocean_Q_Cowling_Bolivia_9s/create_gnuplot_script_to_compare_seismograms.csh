#!/bin/csh

echo \#set term postscript color solid "Helvetica" 22
echo \#set output \"all_seismograms_comparison.ps\"

echo set term pdf color solid
echo set output \"all_seismograms_comparison.pdf\"

#echo set terminal postscript eps color solid
#echo "set output '| epstopdf --filter > all_seismograms_comparison.pdf'"

#echo "set term x11"
#echo "set term wxt"

#echo set xrange \[0:2200\]

foreach file ( SEMD/*.sem.ascii.sac.asciinew )

  set newfile = `basename $file .sem.ascii.sac.asciinew`

  echo plot \"QMXD/$newfile.qmxd.sac.asciinew\" w l lc 1, \"$file\" w l lc 3

# uncomment this only when outputting to the screen (X11 or wxt)
#  echo "pause -1 'hit any key...'"

end

