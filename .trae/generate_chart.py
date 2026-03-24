import os
import json

raw_data = """
2KB.png,2 KB,头部写入脏数据,0.636ms
2KB.png,2 KB,尾部写入脏数据,0.200ms
2KB.png,2 KB,头部加密,0.211ms
2KB.png,2 KB,头部解密(还原),0.472ms

16KB.png,16 KB,头部写入脏数据,0.467ms
16KB.png,16 KB,尾部写入脏数据,0.186ms
16KB.png,16 KB,头部加密,0.248ms
16KB.png,16 KB,头部解密(还原),0.507ms

57KB.png,57 KB,头部写入脏数据,0.555ms
57KB.png,57 KB,尾部写入脏数据,0.198ms
57KB.png,57 KB,头部加密,0.219ms
57KB.png,57 KB,头部解密(还原),0.488ms

116KB.png,124 KB,头部写入脏数据,0.969ms
116KB.png,124 KB,尾部写入脏数据,0.254ms
116KB.png,124 KB,头部加密,0.295ms
116KB.png,124 KB,头部解密(还原),0.534ms

554KB.png,507 KB,头部写入脏数据,5.106ms
554KB.png,507 KB,尾部写入脏数据,0.524ms
554KB.png,507 KB,头部加密,0.626ms
554KB.png,507 KB,头部解密(还原),0.505ms

6100KB.PNG,5.8 MB,头部写入脏数据,29.441ms
6100KB.PNG,5.8 MB,尾部写入脏数据,0.776ms
6100KB.PNG,5.8 MB,头部加密,0.695ms
6100KB.PNG,5.8 MB,头部解密(还原),0.726ms

banjun.mp4,5.3 MB,头部写入脏数据,18.062ms
banjun.mp4,5.3 MB,尾部写入脏数据,0.385ms
banjun.mp4,5.3 MB,头部加密,0.345ms
banjun.mp4,5.3 MB,头部解密(还原),0.654ms

17679260338258.mp4,38.1 MB,头部写入脏数据,222.742ms
17679260338258.mp4,38.1 MB,尾部写入脏数据,0.510ms
17679260338258.mp4,38.1 MB,头部加密,1.426ms
17679260338258.mp4,38.1 MB,头部解密(还原),7.419ms

视频79M.mov,76.1 MB,头部写入脏数据,1.276s
视频79M.mov,76.1 MB,尾部写入脏数据,0.428ms
视频79M.mov,76.1 MB,头部加密,39.319ms
视频79M.mov,76.1 MB,头部解密(还原),63.040ms

视频159M.mov,152.2 MB,头部写入脏数据,2.837s
视频159M.mov,152.2 MB,尾部写入脏数据,0.422ms
视频159M.mov,152.2 MB,头部加密,0.815ms
视频159M.mov,152.2 MB,头部解密(还原),12.838ms

视频319M.mov,304.5 MB,头部写入脏数据,5.574s
视频319M.mov,304.5 MB,尾部写入脏数据,0.894ms
视频319M.mov,304.5 MB,头部加密,1.786ms
视频319M.mov,304.5 MB,头部解密(还原),63.546ms

视频638M.mov,608.9 MB,头部写入脏数据,9.347s
视频638M.mov,608.9 MB,尾部写入脏数据,15.449ms
视频638M.mov,608.9 MB,头部加密,15.329ms
视频638M.mov,608.9 MB,头部解密(还原),182.396ms
"""

def parse_size(size_str):
    size_str = size_str.strip().upper()
    if size_str.endswith("KB"):
        return float(size_str.replace("KB", "").strip()) / 1024.0
    elif size_str.endswith("MB"):
        return float(size_str.replace("MB", "").strip())
    elif size_str.endswith("GB"):
        return float(size_str.replace("GB", "").strip()) * 1024.0
    return 0.0

def parse_time(time_str):
    time_str = time_str.strip()
    if time_str.endswith("ms"):
        return float(time_str.replace("ms", "").strip()) / 1000.0
    elif time_str.endswith("s"):
        return float(time_str.replace("s", "").strip())
    return 0.0

data = {}
for line in raw_data.strip().split('\n'):
    line = line.strip()
    if not line:
        continue
    parts = line.split(',')
    if len(parts) >= 4:
        size_mb = parse_size(parts[1])
        scheme = parts[2].strip()
        time_s = parse_time(parts[3])
        
        if scheme not in data:
            data[scheme] = []
        data[scheme].append((size_mb, time_s))

# Sort by size
for scheme in data:
    data[scheme].sort(key=lambda x: x[0])

# Simple Linear Regression: y = mx + b
def linear_fit(points):
    n = len(points)
    if n == 0: return 0, 0
    sum_x = sum(p[0] for p in points)
    sum_y = sum(p[1] for p in points)
    sum_xy = sum(p[0]*p[1] for p in points)
    sum_xx = sum(p[0]*p[0] for p in points)
    denominator = n * sum_xx - sum_x * sum_x
    if denominator == 0:
        return 0, sum_y/n
    m = (n * sum_xy - sum_x * sum_y) / denominator
    b = (sum_y - m * sum_x) / n
    return m, b

series = []
colors = ['#ee6666', '#fac858', '#73c0de', '#3ba272']

# generate x axis from 0 to 1024 in steps
x_axis = [round(x, 1) for x in list(range(0, 1025, 128))]
if 1024 not in x_axis:
    x_axis.append(1024)
    
i = 0
for scheme, points in data.items():
    m, b = linear_fit(points)
    
    fit_data = []
    for x in x_axis:
        y = m * x + b
        if y < 0: y = 0
        fit_data.append([x, round(y, 4)])
        
    # Scatter points (Actual data)
    series.append({
        'name': scheme + ' (实测)',
        'type': 'scatter',
        'data': [[p[0], p[1]] for p in points],
        'itemStyle': {'color': colors[i % len(colors)]}
    })
    
    # Line points (Extrapolation)
    series.append({
        'name': scheme + ' (1GB拟合趋势)',
        'type': 'line',
        'data': fit_data,
        'showSymbol': False,
        'lineStyle': {'type': 'dashed', 'color': colors[i % len(colors)]}
    })
    i += 1

html_content = f"""<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>不同处理方案耗时趋势 (拟合至1GB)</title>
    <script src="https://cdn.jsdelivr.net/npm/echarts@5.4.3/dist/echarts.min.js"></script>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f7; margin: 0; padding: 40px; }}
        .container {{ background: white; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); padding: 20px; }}
        .header {{ text-align: center; margin-bottom: 20px; }}
        .header h1 {{ margin: 0; color: #333; }}
        .header p {{ color: #666; margin-top: 8px; }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>文件不同处理方案的耗时趋势图</h1>
            <p>包含实测散点数据，以及基于实测数据拟合至 1GB（1024MB）的趋势预测</p>
            <p style="font-size: 13px; color: #999;">💡 提示：因为“头部写入脏数据”耗时过高，其他方案的线几乎贴在X轴上。您可以框选图表下方区域放大查看细节。</p>
        </div>
        <div id="main" style="width: 100%; height: 700px;"></div>
    </div>
    <script>
        var chartDom = document.getElementById('main');
        var myChart = echarts.init(chartDom);
        var option = {{
            tooltip: {{
                trigger: 'axis',
                axisPointer: {{ type: 'cross' }},
                formatter: function (params) {{
                    let res = '<strong>文件大小: ' + params[0].value[0] + ' MB</strong><br/>';
                    for (let i = 0; i < params.length; i++) {{
                        res += params[i].marker + params[i].seriesName + ': ' + params[i].value[1] + ' 秒<br/>';
                    }}
                    return res;
                }}
            }},
            legend: {{
                top: '0%',
                data: {json.dumps([s['name'] for s in series])}
            }},
            grid: {{ left: '5%', right: '5%', bottom: '5%', containLabel: true }},
            toolbox: {{
                feature: {{
                    dataZoom: {{ yAxisIndex: 'none', title: {{ zoom: '区域缩放', back: '还原' }} }},
                    restore: {{ title: '还原' }},
                    saveAsImage: {{ title: '保存为图片' }}
                }}
            }},
            xAxis: {{
                type: 'value',
                name: '文件大小 (MB)',
                nameLocation: 'middle',
                nameGap: 30,
                min: 0,
                max: 1050,
                splitLine: {{ show: true, lineStyle: {{ type: 'dashed', color: '#eee' }} }}
            }},
            yAxis: {{
                type: 'value',
                name: '耗时 (秒)',
                splitLine: {{ show: true, lineStyle: {{ color: '#eee' }} }}
            }},
            series: {json.dumps(series)}
        }};
        myChart.setOption(option);
    </script>
</body>
</html>
"""

os.makedirs('.trae', exist_ok=True)
with open('.trae/performance_chart.html', 'w', encoding='utf-8') as f:
    f.write(html_content)

print("生成成功！")
