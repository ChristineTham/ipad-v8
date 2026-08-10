.PS
copy thru / box "$3" at $1,$2 /
0 0 middle
1 1 upper.right
-1 -1 lower.left
.PE


===================================================================================


.PS
for i = 1 to 5 do X box ht i wid i at 0,0 X
.PE


===================================================================================


.PS
for i = 1 to 5 do X
	if i % 2 == 0 then Y
		circle rad i/2 at 0,0
	Y else Y
		box ht i wid i at 0,0
	Y
X
.PE
