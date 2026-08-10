.sp 1i
.nf
.EQ
= col {a above b above c}
= col 25 {a above b above c}
= col 50 {a above b above c}
= col 100 {a above b above c}
= col 200 {a above b above c}
=
.EN
.EQ
= lcol {a above bbb above ccccc}
= lcol 25 {a above bbb above ccccc}
= lcol 50 {a above bbb above ccccc}
= lcol 100 {a above bbb above ccccc}
= lcol 200 {a above bbb above ccccc}
=
.EN
.EQ
= col {a above b above c}
= col -25 {a above b above c}
= col -50 {a above b above c}
= col -100 {a above b above c}
= col -200 {a above b above c}
=
.EN
.EQ
= lcol {a above bbb above ccccc}
= lcol -25 {a above bbb above ccccc}
= lcol -50 {a above bbb above ccccc}
= lcol -100 {a above bbb above ccccc}
= lcol -200 {a above bbb above ccccc}
=
.EN
.sp .5i
.EQ
left [ matrix {
col {a above b above c}
col 25 {a above b above c}
col 50 {a above b above c}
col 100 {a above b above c}
col 200 {a above b above c}
} right ]
.EN
.sp .5i
.EQ
left [ matrix {
lcol {a above bbb above ccccc}
lcol 25 {a above bbb above ccccc}
lcol 50 {a above bbb above ccccc}
lcol 100 {a above bbb above ccccc}
lcol 200 {a above bbb above ccccc}
} right ]
.EN
.sp .5i
.EQ
left [ matrix {
col {a above b above c}
col -25 {a above b above c}
col -50 {a above b above c}
col -100 {a above b above c}
col -200 {a above b above c}
} right ]
.EN
.sp .5i
.EQ
left [ matrix {
lcol {a above bbb above ccccc}
lcol -25 {a above bbb above ccccc}
lcol -50 {a above bbb above ccccc}
lcol -100 {a above bbb above ccccc}
lcol -200 {a above bbb above ccccc}
} right ]
.EN
