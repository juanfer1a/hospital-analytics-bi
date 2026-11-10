from PIL import Image, ImageDraw, ImageFont
import json
S=2  # supersampling
W,H=1280,720
BG='#FFFFFF'; PANEL='#F5F8FB'; RED='#1F6FB2'; PINK='#2BA6A0'; TXT='#1E2A3A'; MUTED='#5B6B7F'; LINE='#DDE5EE'; BAND='#1F6FB2'; WHITE='#FFFFFF'; SUBW='#CFE2F3'
F='/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf'
FB='/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf'
def f(p,s): return ImageFont.truetype(p,s*S)
M=16; G=12; KY=76; KH=88; CY=176; CB=676

def kpis(n):
    w=(1280-2*M-(n-1)*G)/n
    return [(M+i*(w+G),KY,w,KH,'KPI '+str(i+1)) for i in range(n)]

pages=[
 ('p0_inventario','¿Con qué cuenta el hospital?','Página 0 · Inventario',
   kpis(8),[(16,176,616,244,'Personal por departamento (barras apiladas)'),(644,176,620,244,'Camas por pabellón'),
            (16,432,300,244,'Dona cirujanos vs. no cirujanos'),(328,432,304,244,'Habitaciones por tipo'),(644,432,620,244,'Ficha de capacidad por departamento (tabla)')]),
 ('p1_situacion','El hospital en cifras','Página 1 · Situación',
   kpis(6),[(16,176,820,500,'Tendencia mensual de citas y recaudo'),(848,176,416,500,'Citas por estado')]),
 ('p2_complicacion','La consulta externa tiene un cuello de botella','Página 2 · Complicación',
   kpis(5),[(16,176,500,500,'Citas por médico (barras horizontales)'),(528,176,736,200,'Citas por departamento'),(528,388,736,288,'Mapa de calor: % inasistencia por departamento y trimestre')]),
 ('p3_pregunta','¿Cómo usamos camas y quirófanos?','Página 3 · Pregunta',
   kpis(4),[(16,176,616,500,'Matriz de estancia por pabellón'),(644,176,620,244,'Estancia vs. facturación por tipo de habitación'),(644,432,620,244,'Top 10 tipos de cirugía')]),
 ('p4_respuesta','Pacientes que requieren seguimiento','Página 4 · Respuesta',
   kpis(4),[(16,176,300,240,'Dona crónicos vs. no crónicos'),(328,176,500,240,'Pacientes crónicos por grupo de edad'),(840,176,424,240,'Recomendaciones (cuadro de texto)'),(16,428,1248,248,'Tabla: pacientes con presión alta y próxima visita')]),
]
SLICERS=[(888,12,120,40,'Segmentación: Año'),(1016,12,120,40,'Segmentación: Trimestre'),(1144,12,120,40,'Segmentación: Departamento')]
NAV=(744,690,520,26,'Navegador de páginas')

def R(d,x,y,w,h,fill=None,outline=None,r=10,width=1):
    d.rounded_rectangle([x*S,y*S,(x+w)*S,(y+h)*S],radius=r*S,fill=fill,outline=outline,width=width*S)

def logo(d,x,y):
    # cruz médica
    c=WHITE; u=7
    d.rounded_rectangle([(x+u)*S,y*S,(x+2*u)*S,(y+3*u)*S],radius=2*S,fill=c)
    d.rounded_rectangle([x*S,(y+u)*S,(x+3*u)*S,(y+2*u)*S],radius=2*S,fill=c)
    # línea de pulso
    pts=[(x-2,y+30),(x+6,y+30),(x+10,y+24),(x+15,y+36),(x+19,y+28),(x+23,y+30),(x+32,y+30)]
    d.line([(px*S,py*S) for px,py in pts],fill='#9FD8D4',width=2*S,joint='curve')

coords=[]
for slug,title,sub,k,panels in pages:
    im=Image.new('RGB',(W*S,H*S),BG); d=ImageDraw.Draw(im)
    d.rectangle([0,0,W*S,62*S],fill=BAND)
    logo(d,22,12)
    d.text((64*S,14*S),'Hospital Analytics',font=f(FB,17),fill=WHITE)
    d.text((64*S,36*S),'Gestión de capacidad',font=f(F,11),fill=SUBW)
    d.text((290*S,12*S),title,font=f(FB,20),fill=WHITE)
    d.text((290*S,38*S),sub,font=f(F,11),fill=SUBW)
    for (x,y,w,h,_) in (SLICERS[2:] if slug=='p0_inventario' else SLICERS): R(d,x,y,w,h,fill=WHITE,r=6)
    d.rectangle([0,62*S,W*S,64*S],fill=PINK)
    for (x,y,w,h,_) in k:
        R(d,x,y,w,h,fill=PANEL,outline=LINE)
        d.rounded_rectangle([x*S,(y+14)*S,(x+4)*S,(y+h-14)*S],radius=2*S,fill=RED)
    for (x,y,w,h,_) in panels: R(d,x,y,w,h,fill=PANEL,outline=LINE)
    d.text((16*S,696*S),'Fuente: bi.hospital_gold · Databricks → Power BI',font=f(F,10),fill=MUTED)
    x,y,w,h,_=NAV; R(d,x,y,w,h,outline=LINE,r=6)
    im=im.resize((W,H),Image.LANCZOS); im.save(f'claro/fondo_{slug}.png')
    coords.append((slug,title,[*SLICERS,*k,*panels,NAV]))

md=['# Coordenadas de los paneles (lienzo 1280 × 720)\n','Usar en Power BI: Formato → General → Propiedades → Tamaño y posición.\n']
for slug,title,items in coords:
    md.append(f'\n## {title} (`fondo_{slug}.png`)\n\n| Visual | X | Y | Ancho | Alto |\n|---|---|---|---|---|')
    for (x,y,w,h,l) in items: md.append(f'| {l} | {round(x)} | {round(y)} | {round(w)} | {round(h)} |')
open('claro/coordenadas.md','w',encoding='utf-8').write('\n'.join(md)+'\n')


T='#1E2A3A'; M='#5B6B7F'; B='#1F6FB2'; P='#F5F8FB'; L='#E3E9F0'; W2='#FFFFFF'
c=lambda h:{"solid":{"color":h}}
theme={
 "name":"Hospital Analytics Claro",
 "dataColors":["#1F6FB2","#2BA6A0","#8FB3D9","#F2A65A","#7E6BC4","#5FB98C","#B9CDE3","#5B6B7F"],
 "background":W2,"foreground":T,"tableAccent":B,
 "good":"#2E9E6B","neutral":"#E39B2D","bad":"#C0392B",
 "maximum":B,"center":"#8FB3D9","minimum":"#EAF2FB",
 "textClasses":{
   "callout":{"fontSize":26,"fontFace":"Segoe UI Semibold","color":T},
   "title":{"fontSize":12,"fontFace":"Segoe UI Semibold","color":T},
   "header":{"fontSize":12,"fontFace":"Segoe UI Semibold","color":T},
   "label":{"fontSize":10,"fontFace":"Segoe UI","color":T}},
 "visualStyles":{
   "*":{"*":{
      "background":[{"show":False}],"border":[{"show":False}],"dropShadow":[{"show":False}],
      "visualHeader":[{"foreground":c(M),"background":c(P)}],
      "title":[{"show":True,"fontColor":c(T),"fontSize":12}],
      "categoryAxis":[{"labelColor":c(M),"titleColor":c(M),"gridlineColor":c(L)}],
      "valueAxis":[{"labelColor":c(M),"titleColor":c(M),"gridlineColor":c(L)}],
      "legend":[{"labelColor":c(T)}],
      "labels":[{"color":c(T)}]}},
   "page":{"*":{"background":[{"color":c(W2),"transparency":0}],"outspace":[{"color":c("#EEF2F6")}]}},
   "card":{"*":{"labels":[{"color":c(T),"fontSize":26}],"categoryLabels":[{"color":c(M),"fontSize":11}]}},
   "slicer":{"*":{"items":[{"fontColor":c(T),"background":c(W2)}],"header":[{"fontColor":c(B)}]}},
   "tableEx":{"*":{
      "columnHeaders":[{"fontColor":c(W2),"backColor":c(B)}],
      "values":[{"fontColorPrimary":c(T),"backColorPrimary":c(W2),"fontColorSecondary":c(T),"backColorSecondary":c(P)}]}},
   "pivotTable":{"*":{
      "columnHeaders":[{"fontColor":c(W2),"backColor":c(B)}],
      "rowHeaders":[{"fontColor":c(T),"backColor":c(P)}],
      "values":[{"fontColorPrimary":c(T),"backColorPrimary":c(W2)}]}}
 }}
json.dump(theme,open('claro/hospital_analytics_theme_claro.json','w',encoding='utf-8'),ensure_ascii=False,indent=2)
print('ok')
